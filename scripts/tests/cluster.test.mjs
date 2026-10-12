// RoachNet Cluster end to end, with two runtimes on this Mac standing in for
// two Macs: pairing, a model split across both (the second one is sent its
// shard), replies identical to one Mac's, a stranger refused, and the
// fallback to one Mac when the other goes away.
// Needs ROACHNET_NATIVE_API_BINARY and ROACHNET_TEST_MODELS (qwen3-0.6b-q8_0.gguf).
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const binary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const modelDir = process.env.ROACHNET_TEST_MODELS?.trim() || ''
const qwen = modelDir ? path.join(modelDir, 'qwen3-0.6b-q8_0.gguf') : ''
const needs = binary && qwen && existsSync(qwen) && process.platform === 'darwin' && process.arch === 'arm64'
  ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY and ROACHNET_TEST_MODELS (qwen3-0.6b-q8_0.gguf) on an Apple silicon Mac.' }

async function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

async function startNode(name, { withModel }) {
  const root = await mkdtemp(path.join(os.tmpdir(), `rn-cluster-${name}-`))
  const storage = path.join(root, 'storage')
  if (withModel) {
    const digest = createHash('sha256').update(readFileSync(qwen)).digest('hex')
    const ollama = path.join(storage, 'models', 'ollama')
    mkdirSync(path.join(ollama, 'blobs'), { recursive: true })
    mkdirSync(path.join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'qwen3'), { recursive: true })
    symlinkSync(qwen, path.join(ollama, 'blobs', `sha256-${digest}`))
    writeFileSync(path.join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'qwen3', '0.6b'), JSON.stringify({
      layers: [{ mediaType: 'application/vnd.ollama.image.model', digest: `sha256:${digest}`, size: readFileSync(qwen).length }],
    }))
  } else {
    mkdirSync(storage, { recursive: true })
  }
  const [port, modelPort, clusterPort] = [await freePort(), await freePort(), await freePort()]
  const child = spawn(binary, [], {
    env: {
      PATH: process.env.PATH, HOME: root, HOST: '127.0.0.1', PORT: String(port), ROACHNET_REPO_ROOT: repoRoot,
      ROACHNET_STORAGE_PATH: storage, ROACHNET_COMPANION_ENABLED: '0', ROACHNET_ORG_SCHEDULER: '0',
      OLLAMA_BASE_URL: `http://127.0.0.1:${modelPort}`,
      ROACHNET_CLUSTER_HOST: '127.0.0.1', ROACHNET_CLUSTER_PORT: String(clusterPort), ROACHNET_CLUSTER_BONJOUR: '0',
    },
    stdio: 'ignore',
  })
  const node = { name, root, storage, child, api: `http://127.0.0.1:${port}`, models: `http://127.0.0.1:${modelPort}`, cluster: `127.0.0.1:${clusterPort}` }
  for (let i = 0; i < 150; i += 1) {
    try { if ((await fetch(`${node.models}/api/version`)).ok) return node } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  child.kill('SIGTERM')
  throw new Error(`${name} did not start`)
}

async function call(base, method, route, body) {
  const response = await fetch(`${base}${route}`, { method, headers: { 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) })
  const text = await response.text()
  let json = null
  try { json = JSON.parse(text) } catch {}
  return { status: response.status, json, text }
}

// A trace is finished just after its reply goes out, so give it a moment.
async function tracesTagged(node, tag, atLeast) {
  let traces = []
  for (let i = 0; i < 40; i += 1) {
    traces = (await call(node.api, 'GET', `/api/traces?tag=${tag}&kind=model`)).json?.traces ?? []
    if (traces.length >= atLeast && traces.every((trace) => trace.status !== 'running')) break
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  return traces
}

const MODEL = 'qwen3:0.6b'
const prompts = [
  { prompt: 'The capital of France is', raw: true },
  { prompt: 'RoachNet keeps models, data and agents on your own Mac. ' .repeat(12) + 'In one sentence, what does RoachNet do?' },
]
const generate = (node, item) => call(node.models, 'POST', '/api/generate', {
  model: MODEL, stream: false, think: false, ...item, options: { temperature: 0, num_predict: 16 },
})

test('a model split across two Macs answers exactly as one Mac does', needs, async () => {
  const worker = await startNode('worker', { withModel: false })
  const coordinator = await startNode('coordinator', { withModel: true })
  try {
    // One Mac alone first: the reference answers.
    const reference = []
    for (const item of prompts) reference.push((await generate(coordinator, item)).json.response)
    await generate(coordinator, { prompt: '', keep_alive: 0 })

    // Pair: the worker starts a cluster, the coordinator joins it with the code.
    const started = await call(worker.api, 'PUT', '/api/cluster', { enabled: true, name: 'Studio' })
    assert.equal(started.status, 200, started.text)
    assert.match(started.json.code, /^[0-9A-Z]{4}(-[0-9A-Z]{2,4}){6}$/)
    const joined = await call(coordinator.api, 'PUT', '/api/cluster', {
      enabled: true, name: 'Laptop', code: started.json.code, mode: 'always', peers: [worker.cluster],
    })
    assert.equal(joined.status, 200, joined.text)
    assert.equal(joined.json.fingerprint, started.json.fingerprint, 'both Macs are in one cluster')
    const seen = (await call(coordinator.api, 'GET', '/api/cluster?refresh=1')).json
    assert.equal(seen.peers[0].reachable, true, JSON.stringify(seen.peers))
    assert.equal(seen.peers[0].name, 'Studio')
    assert.ok(seen.peers[0].memory.free > 0)

    // Split: the worker hasn't the model, so it is sent its shard first.
    for (const [index, item] of prompts.entries()) {
      const answer = await generate(coordinator, item)
      assert.equal(answer.status, 200, answer.text)
      assert.equal(answer.json.response, reference[index], `prompt ${index} matches one Mac's answer`)
    }
    const status = (await call(coordinator.api, 'GET', '/api/cluster')).json
    assert.equal(status.models.length, 1)
    const stages = status.models[0].stages
    assert.equal(stages.length, 2)
    assert.equal(stages[1].name, 'Studio')
    assert.equal(stages[0].layers.split(',')[0].split('-')[1], stages[1].layers.split('-')[0], 'the stages meet')
    assert.ok(stages[1].stats.round_trips > 0, 'each hop counts its round trips')
    assert.ok(stages[1].stats.sent_bytes > 0 && stages[1].stats.received_bytes === stages[1].stats.sent_bytes,
      'residuals go out and come back at the same size')
    const split = await tracesTagged(coordinator, 'cluster', prompts.length)
    assert.ok(split.length >= prompts.length, 'each split reply is tagged cluster in its trace')
    assert.ok(split.every((trace) => trace.tags.includes('model-server') && !trace.tags.includes('cluster-fallback')))
    const ps = (await call(coordinator.models, 'GET', '/api/ps')).json.models[0]
    assert.match(ps.backend, /^cluster: Laptop 0–\d+, Studio \d+–28$/)
    const hosted = (await call(worker.api, 'GET', '/api/cluster')).json.stages
    assert.equal(hosted.length, 1)
    const shards = readdirSync(path.join(worker.storage, 'cluster', 'shards')).filter((name) => name.endsWith('.gguf'))
    assert.equal(shards.length, 1, 'the shard was kept for next time')

    // A Mac with another code is refused.
    const stranger = await call(coordinator.api, 'PUT', '/api/cluster', { resetPairing: true })
    assert.notEqual(stranger.json.fingerprint, started.json.fingerprint)
    const refused = (await call(coordinator.api, 'GET', '/api/cluster?refresh=1')).json.peers[0]
    assert.equal(refused.reachable, false)
    assert.match(refused.error, /different cluster/)
    await call(coordinator.api, 'PUT', '/api/cluster', { code: started.json.code })

    // The worker goes away before the next request: nothing has been sent back
    // yet, so that same request is planned again without it and one Mac answers.
    worker.child.kill('SIGKILL')
    await new Promise((resolve) => setTimeout(resolve, 300))
    const alone = await generate(coordinator, prompts[0])
    assert.equal(alone.status, 200, alone.text)
    assert.equal(alone.json.response, reference[0])
    assert.doesNotMatch((await call(coordinator.models, 'GET', '/api/ps')).json.models[0].backend, /cluster/)
    const [rescued] = await tracesTagged(coordinator, 'cluster-fallback', 1)
    assert.ok(rescued, 'the reply answered without the worker is tagged cluster-fallback, so it can be found')
    const after = (await call(coordinator.api, 'GET', '/api/cluster?refresh=1')).json
    assert.equal(after.peers[0].reachable, false, 'the status shows the worker as gone')
    assert.equal(after.models.length, 0, 'no split model is left behind')
  } finally {
    for (const node of [coordinator, worker]) {
      node.child.kill('SIGTERM')
      await rm(node.root, { recursive: true, force: true })
    }
  }
})
