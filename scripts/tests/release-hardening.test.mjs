// Release hardening, run against a built `roachnet-runtime` (point
// ROACHNET_NATIVE_API_BINARY at the helper inside a packaged RoachNet.app to
// check the shipped binary, not just a debug build):
// - numbers no JSON client should send (1e400, -1e400, 1e300) in model and
//   trace requests get a reply instead of crashing the runtime (ROA-59);
// - a RoachTail peer token unused past ROACHTAIL_PEER_IDLE_DAYS is refused,
//   and a recent one still works (ROA-39);
// - with ROACHNET_API_TOKEN set (as RoachNet.app does), the local API wants
//   it, RoachClaw API tokens open only their scopes and stop working once
//   revoked, and other sites' pages are refused (ROA-39, ROA-45);
// - webhook secrets are kept as a salted HMAC in an owner-only file, never in
//   the clear (ROA-39).
// The model checks also need ROACHNET_TEST_MODELS (qwen3-0.6b-q8_0.gguf).
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash, createHmac, randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
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
const modelDir = process.env.ROACHNET_TEST_MODELS?.trim() || ''
const qwen = modelDir ? path.join(modelDir, 'qwen3-0.6b-q8_0.gguf') : ''
const appleSilicon = process.platform === 'darwin' && process.arch === 'arm64'
const needsBinary = binary && existsSync(binary) ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }
const needsModel = binary && existsSync(binary) && qwen && existsSync(qwen) && appleSilicon
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

async function startRuntime(name, { withModel = false, env = {}, prepare } = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), `rn-hardening-${name}-`))
  const storage = path.join(root, 'storage')
  mkdirSync(storage, { recursive: true })
  if (withModel) {
    const bytes = readFileSync(qwen)
    const digest = createHash('sha256').update(bytes).digest('hex')
    const ollama = path.join(storage, 'models', 'ollama')
    mkdirSync(path.join(ollama, 'blobs'), { recursive: true })
    mkdirSync(path.join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'qwen3'), { recursive: true })
    symlinkSync(qwen, path.join(ollama, 'blobs', `sha256-${digest}`))
    writeFileSync(path.join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'qwen3', '0.6b'), JSON.stringify({
      layers: [{ mediaType: 'application/vnd.ollama.image.model', digest: `sha256:${digest}`, size: bytes.length }],
    }))
  }
  prepare?.(storage)
  const [port, modelPort] = [await freePort(), await freePort()]
  const child = spawn(binary, [], {
    env: {
      PATH: process.env.PATH, HOME: root, HOST: '127.0.0.1', PORT: String(port), ROACHNET_REPO_ROOT: repoRoot,
      ROACHNET_STORAGE_PATH: storage, ROACHNET_COMPANION_ENABLED: '0', ROACHNET_ORG_SCHEDULER: '0',
      OLLAMA_BASE_URL: `http://127.0.0.1:${modelPort}`, ROACHNET_CLUSTER_BONJOUR: '0',
      ...env,
    },
    stdio: 'ignore',
  })
  let exited = null
  child.on('exit', (code, signal) => { exited = { code, signal } })
  const node = { root, storage, child, api: `http://127.0.0.1:${port}`, models: `http://127.0.0.1:${modelPort}`, exited: () => exited }
  // The API and the model server come up separately; wait for both.
  for (let i = 0; i < 150; i += 1) {
    try {
      if ((await fetch(`${node.api}/api/health`)).ok && (await fetch(`${node.models}/api/version`)).ok) return node
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  child.kill('SIGTERM')
  throw new Error(`${name} did not start`)
}

async function stop(node) {
  node.child.kill('SIGTERM')
  await rm(node.root, { recursive: true, force: true })
}

// The body is sent as written: JSON.stringify can't spell 1e400.
async function raw(base, method, route, body, headers = {}) {
  const response = await fetch(`${base}${route}`, { method, headers: { 'content-type': 'application/json', ...headers }, body })
  return { status: response.status, text: await response.text() }
}

test('numbers no client should send get a reply, not a crash', needsModel, async (t) => {
  const node = await startRuntime('numbers', { withModel: true })
  try {
    const requests = [
      [node.models, 'POST', '/api/generate',
        '{"model":"qwen3:0.6b","prompt":"Hi","stream":false,"think":false,"options":{"num_predict":2,"top_k":-1e400,"seed":1e300,"repeat_last_n":1e400,"temperature":0}}'],
      [node.models, 'POST', '/api/generate',
        '{"model":"qwen3:0.6b","prompt":"Hi","stream":false,"think":false,"options":{"num_predict":2,"num_ctx":1e400}}'],
      [node.models, 'POST', '/api/chat',
        '{"model":"qwen3:0.6b","stream":false,"think":false,"messages":[{"role":"user","content":"Hi"}],"options":{"num_predict":2,"top_k":1e400,"seed":-1e400}}'],
      [node.models, 'POST', '/v1/chat/completions',
        '{"model":"qwen3:0.6b","max_tokens":4,"messages":[{"role":"user","content":"List"}],"response_format":{"type":"json_schema","json_schema":{"name":"x","schema":{"type":"array","minItems":1e400,"maxItems":-1e400,"items":{"type":"string"}}}}}'],
      [node.models, 'POST', '/api/embed', '{"model":"qwen3:0.6b","input":"hi","dimensions":1e400}'],
      [node.models, 'POST', '/v1/embeddings', '{"model":"qwen3:0.6b","input":"hi","dimensions":-1e400}'],
      [node.api, 'PUT', '/api/traces/settings', '{"maxContentChars":1e400,"retentionDays":-1e400}'],
    ]
    for (const [base, method, route, body] of requests) {
      const reply = await raw(base, method, route, body)
      assert.equal(node.exited(), null, `the runtime is still running after ${method} ${route}`)
      assert.ok(reply.status < 500 || reply.status === 507, `${method} ${route} answered ${reply.status}: ${reply.text.slice(0, 200)}`)
      t.diagnostic(`${method} ${route} -> ${reply.status}`)
    }
    assert.equal((await fetch(`${node.models}/api/version`)).status, 200)
    assert.equal((await fetch(`${node.api}/api/health`)).status, 200)
  } finally {
    await stop(node)
  }
})

test('a RoachTail peer token unused for too long is refused; a recent one works', needsBinary, async () => {
  const fresh = randomBytes(24).toString('hex')
  const stale = randomBytes(24).toString('hex')
  const day = 86_400_000
  const hash = (token) => createHash('sha256').update(token).digest('hex')
  const companionPort = await freePort()
  const node = await startRuntime('peers', {
    env: {
      ROACHNET_COMPANION_ENABLED: '1', ROACHNET_COMPANION_TOKEN: randomBytes(24).toString('hex'),
      ROACHNET_COMPANION_HOST: '127.0.0.1', ROACHNET_COMPANION_PORT: String(companionPort),
      ROACHTAIL_PEER_IDLE_DAYS: '90',
    },
    prepare(storage) {
      const folder = path.join(storage, '.runtime', 'roachtail')
      mkdirSync(folder, { recursive: true })
      writeFileSync(path.join(folder, 'state.json'), JSON.stringify({
        enabled: true,
        peers: [
          { id: 'peer-fresh', name: 'Sample Phone', tokenHash: hash(fresh), createdAt: new Date(Date.now() - 200 * day).toISOString(), lastSeenAt: new Date(Date.now() - 3 * day).toISOString() },
          { id: 'peer-stale', name: 'Old Phone', tokenHash: hash(stale), createdAt: new Date(Date.now() - 200 * day).toISOString(), lastSeenAt: new Date(Date.now() - 120 * day).toISOString() },
        ],
      }))
    },
  })
  try {
    const companion = `http://127.0.0.1:${companionPort}`
    for (let i = 0; i < 50; i += 1) {
      try { if ((await fetch(`${companion}/health`)).ok) break } catch {}
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    const ask = (token) => raw(companion, 'GET', '/api/companion/roachtail', undefined, token ? { authorization: `Bearer ${token}` } : {})
    const refused = await ask(stale)
    assert.equal(refused.status, 401, 'a token idle for 120 days is refused')
    assert.match(refused.text, /pair again/)
    assert.notEqual((await ask(fresh)).status, 401, 'a token used 3 days ago still works')
    assert.equal((await ask('')).status, 401, 'no token, no access')
    assert.equal((await ask(randomBytes(24).toString('hex'))).status, 401, 'an unknown token is refused')
  } finally {
    await stop(node)
  }
})

// node:http, because fetch won't send a Host header of our choosing.
function rawHost(base, route, headers) {
  const url = new URL(route, base)
  return new Promise((resolve, reject) => {
    const request = http.request({ host: url.hostname, port: url.port, path: url.pathname, method: 'GET', headers }, (response) => {
      response.resume()
      response.on('end', () => resolve(response.statusCode))
    })
    request.on('error', reject)
    request.end()
  })
}

test('the local API wants its token, and RoachClaw tokens open only their scopes', needsBinary, async () => {
  const launchToken = randomBytes(32).toString('hex')
  const node = await startRuntime('tokens', { env: { ROACHNET_API_TOKEN: launchToken } })
  const bearer = (token) => ({ authorization: `Bearer ${token}` })
  try {
    assert.equal((await raw(node.api, 'GET', '/api/health')).status, 200, 'health needs no token')
    assert.equal((await raw(node.api, 'GET', '/api/rag/files')).status, 401, 'no token, no API')
    assert.equal((await raw(node.api, 'GET', '/api/rag/files', undefined, bearer(randomBytes(32).toString('hex')))).status, 401)
    assert.equal((await raw(node.api, 'GET', '/api/rag/files', undefined, bearer(launchToken))).status, 200)
    assert.equal((await raw(node.api, 'GET', '/api/rag/files', undefined, { 'x-roachnet-api-token': launchToken })).status, 200)

    // Pages on other sites are refused even with the token (DNS rebinding, CSRF).
    assert.equal(await rawHost(node.api, '/api/rag/files', { host: 'rebind.example', ...bearer(launchToken) }), 403)
    assert.equal((await raw(node.api, 'GET', '/api/rag/files', undefined, { origin: 'https://evil.example', ...bearer(launchToken) })).status, 403)
    const textBody = await fetch(`${node.api}/api/roachclaw/tokens`, {
      method: 'POST', headers: { 'content-type': 'text/plain', ...bearer(launchToken) }, body: '{"name":"x"}',
    })
    assert.equal(textBody.status, 415, 'a body that a page could post without a preflight is refused')

    // A read-only RoachClaw token: reads work, changes don't, and revoking it ends it.
    const minted = await raw(node.api, 'POST', '/api/roachclaw/tokens', JSON.stringify({ name: 'Sample script', scopes: ['read'] }), bearer(launchToken))
    assert.equal(minted.status, 200, minted.text)
    const { token, record } = JSON.parse(minted.text)
    assert.match(token, /^rn_/)
    assert.equal(record.tokenHash, undefined, 'the stored hash is never sent back')
    assert.equal((await raw(node.api, 'GET', '/api/rag/files', undefined, bearer(token))).status, 200)
    const change = await raw(node.api, 'PUT', '/api/traces/settings', '{"retentionDays":7}', bearer(token))
    assert.equal(change.status, 403, change.text)
    assert.equal(JSON.parse(change.text).requiredScope, 'admin')
    assert.equal((await raw(node.api, 'POST', '/api/roachclaw/tokens', '{"scopes":["admin"]}', bearer(token))).status, 403,
      'a read token cannot mint itself a stronger one')
    assert.equal((await raw(node.api, 'DELETE', `/api/roachclaw/tokens/${record.id}`, undefined, bearer(launchToken))).status, 200)
    assert.equal((await raw(node.api, 'GET', '/api/rag/files', undefined, bearer(token))).status, 401, 'a revoked token stops working')
  } finally {
    await stop(node)
  }
})

function findFile(root, name) {
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const full = path.join(root, entry.name)
    if (entry.isFile() && entry.name === name) return full
    if (entry.isDirectory() && !entry.isSymbolicLink()) {
      const found = findFile(full, name)
      if (found) return found
    }
  }
  return null
}

test('webhook secrets are stored as a salted HMAC, never in the clear', needsBinary, async () => {
  const secret = `sample-${randomBytes(16).toString('hex')}`
  const node = await startRuntime('webhooks')
  try {
    const saved = await raw(node.api, 'POST', '/api/roachclaw/webhooks', JSON.stringify({ name: 'Sample hook', secret }))
    assert.equal(saved.status, 200, saved.text)
    assert.ok(!saved.text.includes(secret), 'the reply does not echo the secret')
    const file = findFile(node.storage, 'webhooks.json')
    assert.ok(file, 'the webhook was written')
    assert.equal(statSync(file).mode & 0o777, 0o600, 'only the owner can read it')
    const text = readFileSync(file, 'utf8')
    assert.ok(!text.includes(secret), 'the secret is not on disk')
    const [hook] = JSON.parse(text).webhooks
    assert.equal(hook.secretDigestAlgorithm, 'hmac-sha256-salted-v1')
    assert.match(hook.secretSalt, /^[0-9a-f]{32,}$/)
    assert.notEqual(hook.secretDigest, createHash('sha256').update(secret).digest('hex'), 'not a bare SHA-256')
    assert.equal(hook.secretDigest, createHmac('sha256', hook.secretSalt).update(secret).digest('hex'))
    assert.equal(hook.secretHint, `…${secret.slice(-2)}`, 'the hint shows two characters')
  } finally {
    await stop(node)
  }
})
