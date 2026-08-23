# Whisper Reference Notice

RoachWhisper is RoachNet's Swift/Core ML speech-to-text lane. It is designed as a native Apple Silicon port of the Whisper-style ASR flow, using `ggml-org/whisper.cpp` as the implementation reference and OpenAI Whisper as the model family reference.

## Source Basis

- Reference implementation: `ggml-org/whisper.cpp`
- Repository: `https://github.com/ggml-org/whisper.cpp`
- License: MIT
- Model family: OpenAI Whisper
- RoachNet runtime target: Swift, Core ML, AVFoundation, Accelerate, and Metal-backed Core ML execution

RoachNet must not ship `whisper-cli`, `whisper.cpp` binaries, GGML runtime libraries, or a hidden C/C++ speech sidecar in the native app. The RoachNet codebase can port algorithms, model layout ideas, token contracts, and parity fixtures from whisper.cpp under its MIT license, but attribution stays visible. We can own the RoachNet-native port; we do not erase the upstream history.

## Porting Rules

- Keep the public runtime Apple Silicon native.
- Keep audio ingest in `AVFoundation`.
- Keep signal processing in Swift plus Accelerate.
- Keep model execution in Core ML.
- Keep decode/token orchestration in RoachNet-owned Swift.
- Keep model-pack manifests honest about provenance, conversion commands, and parity status.
- Keep network speech disabled unless the user explicitly selects a future remote lane.

## Release Rule

A RoachWhisper pack can be marked release-ready only when:

- the encoder and decoder are compiled Core ML bundles,
- tokenizer and parity manifests are non-empty,
- the manifest identifies `RoachWares/RoachNet` as the native model-pack owner,
- whisper.cpp is listed as a reference/provenance source, not the shipped runtime,
- native inference is enabled,
- parity has been validated against agreed fixtures,
- no packaged speech binary is present.

No sticker swaps. If the model pack is only an upstream artifact with a new folder name, the release gate should fail.
