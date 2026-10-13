import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import http from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const binary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const needsBinary = binary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }
const modelDir = process.env.ROACHNET_TEST_MODELS?.trim() || ''
const stories = modelDir ? path.join(modelDir, 'stories15M-q4_0.gguf') : ''
const needsModel = binary && stories && existsSync(stories) ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY and ROACHNET_TEST_MODELS (stories15M-q4_0.gguf).' }

async function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

async function startRuntime({ withOllamaModel = false } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'rn-model-server-'))
  const storage = path.join(root, 'storage')
  mkdirSync(storage, { recursive: true })
  if (withOllamaModel) {
    const digest = createHash('sha256').update(readFileSync(stories)).digest('hex')
    const ollama = path.join(storage, 'models', 'ollama')
    mkdirSync(path.join(ollama, 'blobs'), { recursive: true })
    mkdirSync(path.join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'stories'), { recursive: true })
    symlinkSync(stories, path.join(ollama, 'blobs', `sha256-${digest}`))
    writeFileSync(path.join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'stories', '15m'), JSON.stringify({
      layers: [{ mediaType: 'application/vnd.ollama.image.model', digest: `sha256:${digest}`, size: 19077344 }],
    }))
  }
  const port = await freePort()
  const child = spawn(binary, [], {
    env: {
      PATH: process.env.PATH,
      HOME: root,
      HOST: '127.0.0.1',
      PORT: '0',
      ROACHNET_REPO_ROOT: repoRoot,
      ROACHNET_STORAGE_PATH: storage,
      ROACHNET_COMPANION_ENABLED: '0',
      OLLAMA_BASE_URL: `http://127.0.0.1:${port}`,
      ROACHNET_MODEL_PULL_ALLOW_LOOPBACK_HTTP: '1',
    },
    stdio: 'ignore',
  })
  const base = `http://127.0.0.1:${port}`
  for (let i = 0; i < 100; i += 1) {
    try {
      const response = await fetch(`${base}/api/version`)
      if (response.ok) return { root, storage, base, child }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  child.kill('SIGTERM')
  throw new Error('native model server did not start')
}

async function stop(runtime) {
  runtime.child.kill('SIGTERM')
  await rm(runtime.root, { recursive: true, force: true })
}

const post = (base, route, body) => fetch(`${base}${route}`, { method: 'POST', body: JSON.stringify(body) })

test('native model server speaks the Ollama API without any external runner', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    const version = await (await fetch(`${runtime.base}/api/version`)).json()
    assert.match(version.version, /^roachnet-native-/)
    assert.deepEqual(await (await fetch(`${runtime.base}/api/tags`)).json(), { models: [] })
    const missing = await post(runtime.base, '/api/chat', { model: 'nope:1b', messages: [{ role: 'user', content: 'hi' }] })
    assert.equal(missing.status, 404)
    const invalid = await post(runtime.base, '/api/pull', { model: '../../etc/passwd', stream: false })
    assert.equal(invalid.status, 400)
    const unknown = await post(runtime.base, '/api/pull', { model: 'not-in-catalog:1b', stream: false })
    assert.equal(unknown.status, 404)
    const insecure = await post(runtime.base, '/api/pull', { model: 'x:1', url: 'http://example.com/m.gguf', stream: false })
    assert.equal(insecure.status, 400)
    assert.equal((await post(runtime.base, '/api/embed', { model: 'x', input: 'hi' })).status, 404)
    const anthropic = await post(runtime.base, '/v1/messages', { model: 'nope:1b', max_tokens: 5, messages: [{ role: 'user', content: 'hi' }] })
    assert.equal((await anthropic.json()).error.type, 'not_found_error')
  } finally {
    await stop(runtime)
  }
})

test('existing Ollama models are served in place, streamed and OpenAI-compatible', needsModel, async () => {
  const runtime = await startRuntime({ withOllamaModel: true })
  try {
    const tags = await (await fetch(`${runtime.base}/api/tags`)).json()
    assert.equal(tags.models[0].name, 'stories:15m')
    assert.equal(tags.models[0].details.family, 'llama')

    const generated = await (await post(runtime.base, '/api/generate', {
      model: 'stories:15m', prompt: 'Once upon a time', raw: true, stream: false, options: { temperature: 0, num_predict: 10 },
    })).json()
    assert.equal(generated.done, true)
    assert.equal(generated.response, ', there was a little girl named Lily.')
    assert.equal(generated.eval_count, 10)

    const response = await post(runtime.base, '/api/chat', {
      model: 'stories:15m', messages: [{ role: 'user', content: 'Once upon a time' }], options: { temperature: 0, num_predict: 6 },
    })
    const lines = (await response.text()).trim().split('\n').map((line) => JSON.parse(line))
    assert.equal(lines.at(-1).done, true)
    assert.equal(lines.at(-1).eval_count, 6)
    assert.ok(lines.slice(0, -1).every((line) => line.done === false && typeof line.message.content === 'string'))

    const openai = await (await post(runtime.base, '/v1/chat/completions', {
      model: 'stories:15m', messages: [{ role: 'user', content: 'Hi' }], max_tokens: 4, temperature: 0,
    })).json()
    assert.equal(openai.object, 'chat.completion')
    assert.equal(openai.usage.completion_tokens, 4)

    const ps = await (await fetch(`${runtime.base}/api/ps`)).json()
    assert.equal(ps.models.length, 1)
    const del = await fetch(`${runtime.base}/api/delete`, { method: 'DELETE', body: JSON.stringify({ model: 'stories:15m' }) })
    assert.equal(del.status, 409, 'Ollama-owned models are not deleted by RoachNet')
  } finally {
    await stop(runtime)
  }
})

test('pull downloads, verifies sha256, installs, and rejects tampered files', needsModel, async () => {
  const bytes = readFileSync(stories)
  const sha = createHash('sha256').update(bytes).digest('hex')
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'content-length': bytes.length })
    response.end(bytes)
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const url = `http://127.0.0.1:${server.address().port}/stories.gguf`
  const runtime = await startRuntime()
  try {
    const bad = await (await post(runtime.base, '/api/pull', { model: 'tiny:bad', url, sha256: '0'.repeat(64) })).text()
    assert.match(bad, /failed verification/)
    const progress = (await (await post(runtime.base, '/api/pull', { model: 'tiny:good', url, sha256: sha })).text())
      .trim().split('\n').map((line) => JSON.parse(line))
    assert.equal(progress[0].status, 'pulling manifest')
    assert.equal(progress.at(-1).status, 'success')
    const tags = await (await fetch(`${runtime.base}/api/tags`)).json()
    assert.deepEqual(tags.models.map((m) => m.name), ['tiny:good'])
    assert.equal(tags.models[0].digest, sha)
    const shown = await (await post(runtime.base, '/api/show', { model: 'tiny:good' })).json()
    assert.equal(shown.model_info['general.architecture'], 'llama')
    assert.equal((await fetch(`${runtime.base}/api/delete`, { method: 'DELETE', body: JSON.stringify({ model: 'tiny:good' }) })).status, 200)
    assert.deepEqual(await (await fetch(`${runtime.base}/api/tags`)).json(), { models: [] })
  } finally {
    server.close()
    await stop(runtime)
  }
})

// Answers like an Ollama: the bare version a 1.0.x RoachNet's `ollama serve` reports.
function ollamaLookalike() {
  return http.createServer((req, res) => {
    res.setHeader('content-type', 'application/json')
    res.end(req.url === '/api/version' ? '{"version":"0.40.3"}' : '{"models":[{"name":"not-ours:1b"}]}')
  })
}

function listen(server, port) {
  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '127.0.0.1', () => {
      server.off('error', reject)
      resolve(server.address().port)
    })
  })
}

async function closeServer(server) {
  server.closeAllConnections?.()
  await new Promise((resolve) => server.close(resolve))
}

// Starts the runtime with `env` and reports where its model traffic goes.
async function modelLaneOf(env) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'rn-model-port-'))
  const storage = path.join(root, 'storage')
  mkdirSync(storage, { recursive: true })
  const apiPort = await freePort()
  const child = spawn(binary, [], {
    env: {
      PATH: process.env.PATH,
      HOME: root,
      HOST: '127.0.0.1',
      PORT: String(apiPort),
      ROACHNET_REPO_ROOT: repoRoot,
      ROACHNET_STORAGE_PATH: storage,
      ROACHNET_COMPANION_ENABLED: '0',
      ROACHNET_CLUSTER_BONJOUR: '0',
      ...env,
    },
    stdio: 'ignore',
  })
  const api = `http://127.0.0.1:${apiPort}`
  try {
    for (let i = 0; i < 150; i += 1) {
      try {
        // installed-models runs ensureOllama before it answers.
        const models = await (await fetch(`${api}/api/ollama/installed-models`)).json()
        const { ollama } = (await (await fetch(`${api}/api/system/ai/providers`)).json()).providers
        if (ollama.available) {
          const { version } = await (await fetch(`${ollama.baseUrl}/api/version`)).json()
          return { baseUrl: ollama.baseUrl, models: models.map((model) => model.name), version }
        }
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    throw new Error('the runtime never reported a model lane')
  } finally {
    child.kill('SIGTERM')
    await rm(root, { recursive: true, force: true })
  }
}

test("another program on RoachNet's model port keeps it, and RoachInference takes a free one (ROA-72)", needsBinary, async (t) => {
  // Stands in for an `ollama serve` that a 1.0.x RoachNet left running on 127.0.0.1:36434.
  const lookalike = ollamaLookalike()
  // A runtime that another test just stopped can hold the port for a moment.
  const deadline = Date.now() + 10_000
  for (;;) {
    try {
      await listen(lookalike, 36434)
      break
    } catch (error) {
      if (error.code !== 'EADDRINUSE') throw error
      if (Date.now() >= deadline) return t.skip('127.0.0.1:36434 is already in use on this machine')
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
  }
  try {
    const lane = await modelLaneOf({})
    assert.notEqual(lane.baseUrl, 'http://127.0.0.1:36434', "RoachNet's model traffic does not quietly go to the other program")
    assert.match(lane.version, /^roachnet-native-/)
    assert.ok(!lane.models.includes('not-ours:1b'))
    const { version } = await (await fetch('http://127.0.0.1:36434/api/version')).json()
    assert.equal(version, '0.40.3', 'the other program keeps its port and keeps running')
  } finally {
    await closeServer(lookalike)
  }
})

test('a model address somebody set with OLLAMA_BASE_URL is used as configured', needsBinary, async () => {
  const lookalike = ollamaLookalike()
  const modelBase = `http://127.0.0.1:${await listen(lookalike, 0)}`
  try {
    const lane = await modelLaneOf({ OLLAMA_BASE_URL: modelBase })
    assert.equal(lane.baseUrl, modelBase)
    assert.equal(lane.version, '0.40.3')
    assert.deepEqual(lane.models, ['not-ours:1b'])
  } finally {
    await closeServer(lookalike)
  }
})

test("RoachInference never takes Ollama's port, even when OLLAMA_BASE_URL names it (ROA-74)", needsBinary, async () => {
  for (const address of ['http://127.0.0.1:11434', 'http://127.0.0.1']) {
    const lane = await modelLaneOf({ OLLAMA_BASE_URL: address })
    assert.notEqual(lane.baseUrl, 'http://127.0.0.1:11434', `${address}: RoachNet's model traffic stays off Ollama's port`)
    assert.match(lane.version, /^roachnet-native-/, address)
  }
})

test("with ROACHNET_INFERENCE_ENGINE=ollama, the person's running Ollama answers (ROA-74)", needsBinary, async () => {
  const lookalike = ollamaLookalike()
  const ollama = `http://127.0.0.1:${await listen(lookalike, 0)}`
  try {
    const lane = await modelLaneOf({ ROACHNET_INFERENCE_ENGINE: 'ollama', ROACHNET_OLLAMA_URL: ollama })
    assert.equal(lane.baseUrl, ollama)
    assert.equal(lane.version, '0.40.3')
    assert.deepEqual(lane.models, ['not-ours:1b'])
  } finally {
    await closeServer(lookalike)
  }
})

test('with ROACHNET_INFERENCE_ENGINE=ollama and no Ollama running, RoachInference answers and no Ollama is started (ROA-74)', needsBinary, async () => {
  // An `ollama` where 1.1.0 looked for one: it would have been started with `serve`.
  const bin = await mkdtemp(path.join(os.tmpdir(), 'rn-fake-ollama-'))
  const marker = path.join(bin, 'started')
  writeFileSync(path.join(bin, 'ollama'), `#!/bin/sh\necho "$@" > '${marker}'\n`, { mode: 0o755 })
  const nobody = `http://127.0.0.1:${await freePort()}`
  try {
    const lane = await modelLaneOf({ ROACHNET_INFERENCE_ENGINE: 'ollama', ROACHNET_OLLAMA_URL: nobody, ROACHNET_LOCAL_BIN_PATH: bin })
    assert.notEqual(lane.baseUrl, nobody)
    assert.match(lane.version, /^roachnet-native-/)
    assert.equal(existsSync(marker), false, 'RoachNet never runs an ollama binary')
    await assert.rejects(fetch(`${nobody}/api/version`), 'nothing was started where the Ollama would be')
  } finally {
    await rm(bin, { recursive: true, force: true })
  }
})
