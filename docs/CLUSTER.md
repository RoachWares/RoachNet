# RoachNet Cluster

RoachNet Cluster runs one model across several Macs. Each Mac holds a contiguous run of the model's layers. The Mac you ask keeps the embedding and the head, does the sampling, and passes the model's working state (the residual stream) from Mac to Mac. To every app, agent and API, the model looks like any other: tools, structured output, thinking, made models and tracing all work unchanged.

It is off by default, and nothing listens on the network until you turn it on.

## Setting it up

In the RoachNet app, open **Settings › Models › RoachNet Cluster**.

1. **On the first Mac:** turn **Cluster** on. RoachNet makes a pairing code, such as `GQ1M-5Y3Z-V868-3T7H-7FVC-PV8R-VG`.
2. **On each other Mac:** turn **Cluster** on. Under **Join a cluster**, enter the first Mac's code.
3. **On the Mac that will run models:** add the other Macs. Click **Find Macs Nearby**, or type an address such as `studio.local` or `192.168.1.20`. Each one shows its chip and how much memory it can give to models.
4. **Choose how to split:**
   - **Only models too big for this Mac** (the default): a model is split only when this Mac can't hold it alone. Anything that fits stays on one Mac, which is faster.
   - **Every model**: every model is spread across the cluster in proportion to each Mac's free memory.

The first time another Mac runs part of a model, it is sent a shard holding only its layers. It keeps the shard for next time. A Mac that already has the same model file is recognized by the file's SHA-256 and uses its own copy.

**Split right now** shows which Mac holds which layers of each loaded model.

## How a model is split

The planner works from each model's GGUF metadata and asks every Mac for its free memory. It lays the layers out in order:

- This Mac comes first. It keeps the embedding and the head, then takes as many layers as fit.
- Each other Mac then takes layers in turn.
- Every Mac's share covers its weights and its part of the KV cache for the requested context.

If the cluster together is too small, the load fails with a 507 that names the sizes. Each stage's Metal backend is checked against the CPU reference when it loads.

Prompts move from stage to stage as batched residual streams, so each Mac evaluates the prompt with its batched prefill kernels. Decoding sends one residual stream per hop, a few kilobytes per token per Mac. On a wired or fast Wi-Fi network that adds a millisecond or two per Mac to each token.

## Security

- **The pairing code is a 128-bit secret.** It never crosses the network.
- **Every connection starts with a handshake.** Each end proves it holds the secret with an HMAC over fresh random nonces. A Mac with another code is refused.
- **Every message after the handshake is sealed.** Messages use ChaCha20-Poly1305 under keys derived (HKDF-SHA256) for that connection alone, with counter nonces, so a message can't be read, forged, replayed or reordered.
- **Discovery is not trust.** Macs advertise themselves over Bonjour as `_roachnet-cluster._tcp` so they can be found. Being listed gives a Mac nothing; it still needs the pairing code.
- **Shards are checked.** A shard is verified against its SHA-256 before it is used. A damaged transfer is discarded and sent again. A transfer that is cut off resumes where it stopped.
- **Starting over is one click.** **New Code** makes a new secret. The other Macs then stop trusting this one until they join again.

macOS asks once for permission to use the local network the first time Cluster connects to another Mac.

## When a Mac goes away

If a Mac drops out while a reply is being written, that reply fails with a 502. The split model is marked broken, and the next request plans it again across the Macs that answer. If none answer, the model runs on this Mac alone. Stages that a Mac runs for others are released when the other Mac unloads the model, or after 30 idle minutes.

## API

The runtime's loopback API (owner only):

| Route | |
| --- | --- |
| `GET /api/cluster` | This Mac, the other Macs (asked live with `?refresh=1`), the pairing code and fingerprint, and how loaded models are split |
| `PUT /api/cluster` | `{enabled, name, mode: "auto" \| "always", peers: ["host:port"], code: "<pairing code>", resetPairing: true}` |
| `POST /api/cluster/peers`, `DELETE /api/cluster/peers` | `{address}` |
| `GET /api/cluster/nearby` | Macs advertising Cluster on this network |

Settings live in `<storage>/state/cluster.json` (mode 0600). Shards live in `<storage>/cluster/shards`.

## Environment

| Variable | |
| --- | --- |
| `ROACHNET_CLUSTER_PORT` | The cluster port (default 7419) |
| `ROACHNET_CLUSTER_HOST` | The address to listen on (default all interfaces). The tests use `127.0.0.1` |
| `ROACHNET_CLUSTER_BONJOUR=0` | Don't advertise over Bonjour |
| `ROACHNET_MODEL_MEMORY_GB` | How much memory models may use on this Mac. This also sets what the Mac offers the cluster |

## Limits

- **Apple silicon Macs only.** Every stage runs on the Metal backend.
- **Activations travel in FP32,** so stages compute exactly what one Mac would.
- **A model's architecture must be supported** by RoachInference (llama, mistral, qwen2, qwen3).

## How it is tested

- **`scripts/tests/cluster.test.mjs`** runs two runtimes on one Mac, standing in for two Macs, with qwen3 0.6B. It checks four things:
  - pairing works;
  - the second runtime is sent its shard;
  - replies are identical to one Mac's;
  - a runtime with another code is refused, and when the second runtime is killed, the cluster falls back to one Mac.
- **`ModelStageTests`** cuts a model into shard files and chains the stages, batched and decoding, against the whole model.
- **`ClusterTests`** covers pairing codes, the sealed channel (replay, tampering, a wrong key), the planner, and address parsing.

## Source

`native/macos/Sources/RoachNetRuntime/Cluster/`:

| File | What it does |
| --- | --- |
| `ClusterSecurity.swift` | Pairing secret, handshake, sealed channel |
| `ClusterLink.swift` | Framed TCP connections and the listener |
| `ClusterNode.swift` | Settings, status, serving connections |
| `ClusterStages.swift` | Stages run for other Macs |
| `ClusterPipeline.swift` | Planner, the coordinator's backend, shard sending |
| `ClusterServing.swift` | Loading a split model in the model server |
| `ClusterBonjour.swift` | Discovery |
| `ClusterRoutes.swift` | `/api/cluster` |

In `RoachInference`, `ModelStage`, `GGUFShard` and the stage entry points on the CPU and Metal backends do the model side.
