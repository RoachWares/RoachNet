# RoachSpeech Runtime

RoachSpeech is the native voice lane for RoachClaw and the command bar. The release rule is simple: no `whisper-cli`, no Piper sidecar, no C/C++ speech engine hidden in the app bundle.

## Source Basis

RoachWhisper starts from `ggml-org/whisper.cpp` as the proven Whisper implementation reference. The RoachNet runtime path is our Swift/Core ML port: `AVFoundation` for audio ingest, Accelerate for signal prep, Core ML for model execution, and RoachNet-owned Swift for token/decode orchestration.

The upstream code is MIT-licensed, so RoachNet can port and improve it while keeping attribution. We can call the native port RoachWhisper because the integration, model-pack contract, app wiring, and release gate are RoachNet-owned. We cannot pretend the research and reference implementation have no history. The notice lives at `docs/third-party/WHISPER_REFERENCE.md`.

## Native-Only Rule

RoachSpeech runtime code must stay Swift-first:

- app shell: SwiftUI/AppKit
- audio IO and conversion: `AVFoundation`
- feature extraction and DSP: Swift plus Accelerate/Metal where useful
- model execution: Core ML on Apple Silicon
- orchestration: RoachNet Swift types

Python can exist as a user language inside the Dev workspace. It cannot become the speech runtime, model host, installer dependency, or hidden conversion service inside the shipped app. Build/import tooling may use Node scripts to fetch already-compiled Core ML packs, but release packaging must not require Python, `coremltools`, `whisper-cli`, or any local C/C++ speech sidecar on the user's machine.

## v1.0.5 Release Contract

- Speech-to-text: Apple `Speech.framework` with `requiresOnDeviceRecognition = true`.
- Text-to-speech: Apple `AVSpeechSynthesizer`.
- Network speech: disabled.
- Packaged speech binaries: forbidden by `scripts/audit-native-release-scope.mjs`.
- Custom neural voice cloning: not advertised as complete unless a native RoachVoice Core ML pack is present and marked release-ready.
- Whisper-style transcription: only advertised as RoachWhisper when a RoachNet-owned Swift/Core ML pack is present and parity-gated. `whisper.cpp` is STT, not voice cloning.

If on-device recognition is not available on a Mac, RoachSpeech reports the voice lane as unavailable instead of falling back to server dictation. The cloud can stay outside.

## Native Model Pack Layout

Model packs are local folders with a `RoachSpeechPack.json` manifest. They are switchable and upgradable by replacing the pack path or loading a newer pack version. A manifest must declare:

- `packID`
- `displayName`
- `version`
- `kind`: `roachWhisper` or `roachVoice`
- `nativeFormat`: `coreML`
- `features`: for example `speechToText`, `transcriptSidecars`, `customVoiceSynthesis`
- `noNetwork: true`
- `noPackagedBinary: true`
- `nativeInferenceReady`
- `parityValidated`

RoachNet treats staged assets and release-ready assets differently. Staged assets can be detected and shown in status, but RoachNet must keep using the Apple fallback until the manifest and native backend prove the feature is complete.

## Public Bundle Profile

The public v1.0.5 desktop build uses the `baseline` RoachSpeech bundle profile. That profile keeps first-run speech useful without turning every installer into a model dump:

- bundled: `roachwhisper-openai-whisper-base-en-coreml`
- bundled: `roachvoice-kokoro-82m-int8-coreml`
- optional App Store pack: `roachvoice-chatterbox-coreml`

`scripts/build-native-macos-apps.mjs` still supports `ROACHNET_ROACHSPEECH_BUNDLE_PROFILE=full` for internal test builds that intentionally carry every pack. Public builds should stay on `baseline`; the setup app ships faster, then the native API installs heavier packs into:

```text
~/RoachNet/storage/RoachSpeech/ModelPacks/
```

The app searches that storage shelf plus bundled resources, so installing `roachvoice-chatterbox-coreml` restores the full cloning-capable RoachVoice lane without regressing the baseline app.

Builds also produce first-party pack archives. Public installs discover them through Apps.RoachNet.org same-origin descriptors, then fetch the binaries from public source rails listed in those descriptors. GitHub stays focused on code and installer artifacts, Netlify stays focused on the storefront, and no user machine becomes production storage:

```text
https://apps.roachnet.org/downloads/model-packs/roachvoice-chatterbox-coreml.json
https://apps.roachnet.org/downloads/model-packs/roachvoice-kokoro-82m-int8-coreml.json
https://apps.roachnet.org/downloads/model-packs/roachwhisper-openai-whisper-base-en-coreml.json
```

The RoachNet App Store points at those descriptors through `roachspeech-pack` install intents. Downloads are resolved from descriptor sources, staged through `.downloads`, unpacked with the macOS native archive tool, validated against `RoachSpeechPack.json`, and atomically swapped into the active model shelf. A bad archive does not erase a working pack.

First-party Apps descriptors are chunk-aware for Internet Archive. Each archive part is published as a `ROACHNET-IA-CHUNK-v1` envelope instead of a raw ZIP slice, because IA rejects the first raw slice as a corrupt archive. The default payload part is `8 MiB`, large enough to avoid thousands of brittle PUT requests and small enough to retry without restarting the whole archive. The native API strips the envelope, verifies the part SHA-256, reassembles the payload into the original ZIP, verifies the full archive SHA-256, then installs it. The v1.0.5 public model lane publishes `229` wrapped parts across the three first-party RoachSpeech archives and all parts passed redirect-aware `HEAD` verification with exact encoded byte lengths against:

```text
https://archive.org/download/roachnet-apps-catalog-v1_0_5/
```

Chunk descriptors default to `upload-required` until the complete part set is mirrored. The native app only uses `internet-archive-parts` sources when the descriptor marks that lane live, so a half-published model pack fails closed instead of failing halfway through a user install.

The same descriptor resolver is used for Apps map and ZIM downloads. Apps.RoachNet.org keeps descriptor JSON for the whole static catalog; Internet Archive is the managed mirror target, and original public sources remain active fallbacks until a mirror is populated.

## RoachWhisper STT Target

The native Whisper-style lane should be implemented as Swift plus Core ML. RoachNet can use whisper.cpp's generated Core ML encoder as a reference artifact while the native decoder/tokenizer path is being built, because upstream documents `./models/generate-coreml-model.sh base.en` producing `models/ggml-base.en-encoder.mlmodelc` for Apple Silicon Core ML acceleration. That is only the encoder base. It is not a complete RoachNet native STT runtime by itself, and it is not enough to ship.

The current STT reference set is intentionally pragmatic. AssemblyAI's 2026 open-source STT review frames the same tradeoffs RoachNet has to respect: Whisper wins when transcript quality matters more than live latency, Wav2Vec2 and NeMo-style models are better customization/streaming candidates, and Vosk is useful when resource cost matters more than perfect accuracy. RoachNet's default lane stays Whisper-family because Vault transcripts, lyrics, books, and RoachClaw context need robust offline transcription first. Low-latency streaming can be a separate model pack later, not a reason to ship a Python service today.

For Apple Silicon sizing:

- Desktop release target: Whisper-family Core ML pack, starting with small/base parity packs and graduating to larger V3 Turbo-class packs only when installer size and memory gates pass.
- iOS release target: smaller Distil-Whisper, Moonshine, or Parakeet-style packs only after license, Core ML conversion, and on-device memory tests pass.
- Remote STT APIs: useful for benchmarking, not a default RoachNet custody lane.

```text
RoachSpeech/ModelPacks/RoachWhisperSmall/
  RoachSpeechPack.json
  RoachWhisper/
    RoachWhisperEncoder.mlmodelc
    RoachWhisperDecoder.mlmodelc
    RoachWhisperTokenizer.json
    RoachWhisperParity.json
```

That keeps model execution on Apple Silicon through Core ML / Metal, with Swift owning tokenization, decode control, permissions, and RoachClaw handoff. Open-source model weights can be converted during the build/prep lane, but the shipped app must not depend on a user-installed binary or a C/C++ runtime.

RoachNet must not call this lane release-ready or describe it as whisper-compatible until the parity manifest proves the native Swift/Core ML path matches the whisper.cpp command behavior we rely on: same input audio class, same transcript contract, same offline privacy boundary, and no server detour. Until then, Apple on-device Speech is the honest fallback.

### Staging A whisper.cpp Core ML Encoder

Use the importer to copy the generated encoder into RoachNet's model-pack layout and record reference provenance:

```bash
node scripts/import-roachspeech-coreml-from-whispercpp.mjs \
  --model base.en \
  --whispercpp-models /path/to/whisper.cpp/models \
  --upstream-commit <whisper.cpp commit>
```

That creates a staged pack with `nativeInferenceReady: false` and `parityValidated: false`. Staged imports are useful for development only. The importer refuses `--release-ready` because v1.0.5 must ship RoachNet-owned Core ML packs, not upstream whisper.cpp assets with a new sticker on the box.

### Staging A Complete Core ML Whisper Model Base

If we need a stronger starting point than the encoder-only whisper.cpp export, stage an existing Core ML Whisper model bundle as input material:

```bash
node scripts/import-roachwhisper-coreml-from-whisperkit.mjs \
  --repository argmaxinc/whisperkit-coreml \
  --model openai_whisper-base.en
```

That importer downloads Core ML encoder, decoder, and mel model assets into the RoachSpeech model-pack layout and writes a staged manifest. It still refuses `--release-ready`. The reason is boring and important: model files are not the whole speech engine. RoachNet still needs the native tokenizer/decode loop and parity fixtures before this becomes the public RoachWhisper lane.

The staged pack must at least pass a native Core ML execution smoke:

```bash
node scripts/smoke-test-roachspeech-coreml-packs.mjs
```

That command runs zero audio through the mel model, encoder, and first decoder step using Swift/Core ML. Passing it proves the compiled assets execute on Apple Silicon. It does not prove transcript parity; the release audit still keeps `nativeInferenceReady` and `parityValidated` false until RoachNet owns the full decode loop and fixtures.

### Creating A RoachNet-Owned RoachWhisper Pack

Once the native Swift/Core ML model host and assets exist, build the release pack with RoachNet ownership:

```bash
node scripts/create-roachspeech-native-pack.mjs \
  --kind roachWhisper \
  --pack-id roachwhisper-base-en-coreml \
  --display-name "RoachWhisper base.en" \
  --version 1.0.5 \
  --encoder /path/to/RoachWhisperEncoder.mlmodelc \
  --decoder /path/to/RoachWhisperDecoder.mlmodelc \
  --tokenizer /path/to/RoachWhisperTokenizer.json \
  --parity /path/to/RoachWhisperParity.json \
  --reference "ggml-org/whisper.cpp architecture reference"
```

The release audit requires RoachWares/RoachNet ownership in the manifest, non-empty `.mlmodelc` bundles, and non-empty tokenizer/parity files. Empty test bundles, encoder-only imports, and manifest claims that point to whisper.cpp as the pack owner fail the v1.0.5 gate.

## RoachVoice TTS And Custom Voice Target

RoachVoice is the separate TTS and custom voice pack contract. It is not part of whisper.cpp and must not be described as Whisper voice cloning.

The final public RoachVoice target is a RoachNet-native Chatterbox-Turbo Core ML pack. Chatterbox-Turbo is the reference because it is MIT-licensed, built for expressive TTS, supports voice cloning, supports emotion/paralinguistic control, and has an ONNX reference pack that is useful for conversion work. RoachNet must not ship that ONNX/PyTorch stack directly. The release pack must be converted into RoachNet-owned `.mlmodelc` bundles and driven from Swift.

Kokoro stays useful as a small fallback/development narrator because it is tiny and Apache-2.0, but it is not the final custom voice/cloning lane. If a build only contains Kokoro, RoachSpeech may use it as basic local narration, but v1.0.5 must not claim complete RoachClaw voice cloning.

Current pack status:

- `roachvoice-kokoro-82m-int8-coreml` is staged as the small local narrator pack.
- `roachvoice-chatterbox-coreml` is staged as the cloning-capable Chatterbox Core ML pack. It includes the full T3 transformer, speech tokenizer, flow, vocoder, voice encoder, and CAMPPlus speaker encoder pipeline compiled with `xcrun coremlcompiler`.
- `roachwhisper-openai-whisper-base-en-coreml` is release-ready for the v1.0.5 native lane after passing mel, encoder, first decoder step, tokenizer, silence hallucination, and JFK transcript parity fixtures through RoachNet's Swift/Core ML path.
- `ResembleAI/chatterbox-turbo-ONNX` was evaluated for the final Turbo pack. The smallest `q4f16` graph still contains Microsoft ONNX Runtime-only ops such as `GatherBlockQuantized`, `MatMulNBits`, `GroupQueryAttention`, and `MultiHeadAttention`; `coremltools` 9 no longer has an ONNX frontend; `onnx-coreml` is incompatible with current coremltools; and `onnx2torch` fails on those ops/dynamic paths. Until those ops are lowered into Swift/Core ML or a real Turbo `.mlpackage` source exists, Turbo remains a hard release-quality target, not a flag we fake in a manifest.

Create the current Chatterbox Core ML cloning pack with:

```bash
node scripts/import-roachvoice-chatterbox-coreml.mjs \
  --repository yepher/screen-cut-pro-tts-coreml \
  --version 1.0.5
```

```text
RoachSpeech/ModelPacks/RoachVoiceChatterboxTurbo/
  RoachSpeechPack.json
  RoachVoice/
    RoachVoiceLanguageModel.mlmodelc
    RoachVoiceConditionalDecoder.mlmodelc
    RoachVoiceSpeechEncoder.mlmodelc
    RoachVoiceEmbedTokens.mlmodelc
    RoachVoiceTokenizer.json
    RoachVoiceEmbedding.json
```

The Chatterbox-Turbo-derived manifest must include:

- `customVoiceSynthesis`
- `voiceCloning`
- `paralinguisticTags`
- `watermarking`
- `provenance.upstreamProject: "RoachWares/RoachNet"`
- `provenance.referenceProject` mentioning `ResembleAI/chatterbox-turbo`

Create a RoachNet-native Chatterbox-Turbo pack from already-converted Core ML components with:

```bash
node scripts/create-roachspeech-native-pack.mjs \
  --kind roachVoice \
  --pack-id roachvoice-chatterbox-turbo-coreml \
  --display-name "RoachVoice Chatterbox-Turbo" \
  --version 1.0.5 \
  --language-model /path/to/RoachVoiceLanguageModel.mlmodelc \
  --conditional-decoder /path/to/RoachVoiceConditionalDecoder.mlmodelc \
  --speech-encoder /path/to/RoachVoiceSpeechEncoder.mlmodelc \
  --embed-tokens /path/to/RoachVoiceEmbedTokens.mlmodelc \
  --tokenizer /path/to/RoachVoiceTokenizer.json \
  --embedding /path/to/RoachVoiceEmbedding.json \
  --reference "ResembleAI/chatterbox-turbo MIT reference"
```

Do not place `.onnx`, `.pt`, `.pth`, `.safetensors`, `.gguf`, Python scripts, or a model server inside `native/macos/Vendor/RoachSpeech`. The audit rejects those. If it is not Swift plus Core ML at runtime, it is not the native RoachVoice lane.

### Small Narrator Fallback

```text
RoachSpeech/ModelPacks/RoachClawVoice/
  RoachSpeechPack.json
  RoachVoice/
    RoachVoiceNarrator.mlmodelc
    RoachVoiceG2PEncoder.mlmodelc
    RoachVoiceG2PDecoder.mlmodelc
    RoachVoiceEmbedding.json
```

Split acoustic/vocoder packs are also supported when a model family needs them:

```text
RoachVoice/
  RoachVoiceAcoustic.mlmodelc
  RoachVoiceVocoder.mlmodelc
  RoachVoiceEmbedding.json
```

Create the default native Kokoro pack with:

```bash
node scripts/import-roachvoice-kokoro-coreml.mjs \
  --repository aufklarer/Kokoro-82M-CoreML-INT8 \
  --version 1.0.5
```

Custom voice projects can be created from microphone recordings or imported local audio. The native app tracks sample source, local file path, total duration, and readiness. The current minimum prep gate is 30 seconds of local-only sample audio, with 180 seconds recommended for a stronger voice project.

Until a RoachVoice model pack exists and the native inference backend is marked ready, RoachClaw spoken replies continue through `AVSpeechSynthesizer`. Custom profiles remain selectable as projects and pack references, but status must say `Custom voice pack staged; native synthesis gated` instead of pretending neural synthesis is live.

Create a basic split synthesis pack with:

```bash
node scripts/create-roachspeech-native-pack.mjs \
  --kind roachVoice \
  --pack-id roachvoice-default-coreml \
  --display-name "RoachVoice Default" \
  --version 1.0.5 \
  --acoustic /path/to/RoachVoiceAcoustic.mlmodelc \
  --vocoder /path/to/RoachVoiceVocoder.mlmodelc \
  --embedding /path/to/RoachVoiceEmbedding.json
```

That pack can enable custom synthesis if the model family supports it, but the v1.0.5 public cloning gate expects the Chatterbox-Turbo component layout above.

## Vault Contracts

RoachSpeech exposes deterministic action plans for Vault use:

- `readAloud`: books, PDFs, markdown, and text can use the current voice profile. System voice fallback is allowed.
- `transcribeAudio`: audio files require a release-ready native RoachWhisper pack.
- `transcribeVideo`: video files require a release-ready native RoachWhisper pack.
- `extractLyrics`: music/audio lyric extraction requires a release-ready native RoachWhisper pack.
- `generateTranscriptSidecar`: stages sidecar output paths like `song.transcript.json` and requires a release-ready native RoachWhisper pack before execution.

Sidecar path generation is pure and local. It does not upload media and does not call a helper binary.

## Release Gate

Run this before packaging:

```bash
node scripts/audit-native-release-scope.mjs
node scripts/smoke-test-roachspeech-coreml-packs.mjs
```

The full release gate calls the same audit. If somebody sneaks a speech sidecar back into the bundle, the build should fail loudly instead of shipping another fake-native lane.

For v1.0.5, the audit also requires:

- at least one complete `roachWhisper` pack under `native/macos/Vendor/RoachSpeech/ModelPacks`
- RoachWares/RoachNet ownership for every release-ready RoachSpeech pack
- whisper.cpp only as a reference/provenance note for RoachWhisper, not as the runtime or pack owner
- non-empty RoachWhisper encoder and decoder `.mlmodelc` bundles
- non-empty RoachWhisper tokenizer and parity JSON files
- a release-ready RoachWhisper parity manifest with a silence guard and a whisper.cpp transcript fixture
- at least one complete `roachVoice` pack under the same model-pack root
- Chatterbox-Turbo provenance for the final cloning pack
- non-empty RoachVoice Chatterbox-Turbo `.mlmodelc` components, tokenizer, and voice embedding file
- no upstream `.onnx`, `.pt`, `.pth`, `.safetensors`, or `.gguf` blobs in the shipped RoachSpeech bundle

The native release gate also needs RoachSpeech tests proving:

- no packaged speech binary dependency is reported
- staged Core ML RoachWhisper assets only claim parity after the manifest records the native fixture checks
- custom voice projects stay local-only and duration-gated
- voice profiles can switch or upgrade by model pack path
- Vault transcript and lyric plans require a release-ready native RoachWhisper pack
- system voice fallback remains available when no custom voice pack exists
