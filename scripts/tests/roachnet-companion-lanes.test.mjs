import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { createServer } from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { requestHttp } from '../lib/roachnet_http.mjs'

// The companion lanes the iOS companion has used since v1.0.5 (chat sessions,
// service, account and RoachSync actions), exercised over the token-gated bridge
// exactly as the phone calls them. Native runtime only.
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const nativeApiBinary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const nativeOnly = nativeApiBinary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

async function freePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

async function call(url, { method = 'GET', body, token } = {}) {
  const response = await requestHttp(url, {
    method,
    headers: {
      Accept: 'application/json',
      ...(body ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
    timeoutMs: 10_000,
  })
  return { status: response.status, json: JSON.parse(await response.text()) }
}

async function startFakeModelLane({ reply }) {
  const seen = []
  const server = createServer((request, response) => {
    let raw = ''
    request.on('data', (chunk) => { raw += chunk })
    request.on('end', () => {
      response.setHeader('Content-Type', 'application/json')
      if (request.url === '/api/version') return response.end(JSON.stringify({ version: '0.0.0-test' }))
      if (request.url === '/api/tags') return response.end(JSON.stringify({ models: [{ name: 'test-model:latest', size: 1 }] }))
      if (request.url === '/api/chat' && request.method === 'POST') {
        const body = JSON.parse(raw || '{}')
        seen.push(body)
        if (!reply) { response.statusCode = 503; return response.end(JSON.stringify({ error: 'down' })) }
        return response.end(JSON.stringify({ model: body.model, message: { role: 'assistant', content: reply(body) }, done: true }))
      }
      response.statusCode = 404
      response.end(JSON.stringify({ error: 'not found' }))
    })
  })
  const port = await new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)))
  return { port, seen, close: () => new Promise((resolve) => server.close(resolve)) }
}

async function withRuntime(modelLane, run) {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-companion-lanes-'))
  const storagePath = path.join(tempRoot, 'storage')
  mkdirSync(path.join(tempRoot, 'sync-folder'), { recursive: true })
  const port = await freePort()
  const companionPort = await freePort()
  const token = 'companion-lanes-primary-token'
  const env = {
    ...process.env,
    HOME: tempRoot,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: path.join(tempRoot, 'state'),
    ROACHNET_COMPANION_ENABLED: '1',
    ROACHNET_COMPANION_HOST: '127.0.0.1',
    ROACHNET_COMPANION_PORT: String(companionPort),
    ROACHNET_COMPANION_TOKEN: token,
    OLLAMA_BASE_URL: `http://127.0.0.1:${modelLane.port}`,
    ROACHNET_ROACHCLAW_DEFAULT_MODEL: 'test-model:latest',
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(nativeApiBinary, [], { cwd: repoRoot, env, stdio: ['ignore', 'pipe', 'pipe'] })
  try {
    const startedAt = Date.now()
    while (true) {
      if (child.exitCode !== null) throw new Error(`runtime exited: ${child.exitCode}`)
      try { if ((await call(`http://127.0.0.1:${port}/api/health`)).status === 200) break } catch {}
      if (Date.now() - startedAt > 20_000) throw new Error('runtime health timed out')
      await new Promise((resolve) => setTimeout(resolve, 250))
    }
    const bridge = (pathname, options = {}) => call(`http://127.0.0.1:${companionPort}${pathname}`, { ...options, token })
    await run({ bridge, tempRoot })
  } finally {
    await new Promise((resolve) => {
      const stop = spawn(nativeApiBinary, ['--stop'], { cwd: repoRoot, env, stdio: 'ignore' })
      stop.once('close', resolve)
    })
    if (child.exitCode === null) child.kill('SIGKILL')
    await rm(tempRoot, { recursive: true, force: true })
  }
}

test('companion chat keeps sessions and relays to the local model lane', nativeOnly, async () => {
  const lane = await startFakeModelLane({ reply: (body) => `echo: ${body.messages.at(-1).content}` })
  try {
    await withRuntime(lane, async ({ bridge }) => {
      assert.deepEqual((await bridge('/api/companion/chat/sessions')).json, [])

      const created = await bridge('/api/companion/chat/sessions', { method: 'POST', body: { title: 'Field notes' } })
      assert.equal(created.status, 201)
      assert.equal(created.json.title, 'Field notes')
      assert.equal(typeof created.json.id, 'string')

      const sent = await bridge('/api/companion/chat/send', {
        method: 'POST',
        body: { sessionId: created.json.id, content: 'Where is the water filter?', images: ['aGk='], visionSummary: 'A shelf.' },
      })
      assert.equal(sent.status, 200, JSON.stringify(sent.json))
      assert.equal(sent.json.session.id, created.json.id)
      assert.equal(sent.json.session.model, 'test-model:latest')
      assert.equal(sent.json.userMessage.role, 'user')
      assert.match(sent.json.userMessage.content, /\[Vision attachment: 1\]\nA shelf\./)
      assert.equal(sent.json.assistantMessage.role, 'assistant')
      assert.match(sent.json.assistantMessage.content, /^echo: Where is the water filter\?/)
      assert.deepEqual(lane.seen.at(-1).messages.at(-1).images, ['aGk='])
      assert.equal(lane.seen.at(-1).stream, false)

      // A send without a session starts one and titles it from the first line.
      const fresh = await bridge('/api/companion/chat/send', { method: 'POST', body: { content: 'Plan a hike\nwith water stops' } })
      assert.equal(fresh.status, 200)
      assert.equal(fresh.json.session.title, 'Plan a hike')

      const list = (await bridge('/api/companion/chat/sessions')).json
      assert.equal(list.length, 2)
      const detail = await bridge(`/api/companion/chat/sessions/${encodeURIComponent(created.json.id)}`)
      assert.equal(detail.status, 200)
      assert.deepEqual(detail.json.messages.map((message) => message.role), ['user', 'assistant'])
      assert.equal(typeof detail.json.messages[0].createdAt, 'string')

      assert.equal((await bridge('/api/companion/chat/sessions/does-not-exist')).status, 404)
      assert.equal((await bridge('/api/companion/chat/send', { method: 'POST', body: { content: '  ' } })).status, 400)
    })
  } finally {
    await lane.close()
  }
})

test('companion chat reports an unreachable model lane without a fake reply', nativeOnly, async () => {
  const lane = await startFakeModelLane({ reply: null })
  try {
    await withRuntime(lane, async ({ bridge }) => {
      const sent = await bridge('/api/companion/chat/send', { method: 'POST', body: { content: 'Hello?' } })
      assert.equal(sent.status, 503)
      assert.match(sent.json.error, /can't reach a local model/)
      const [session] = (await bridge('/api/companion/chat/sessions')).json
      const detail = (await bridge(`/api/companion/chat/sessions/${encodeURIComponent(session.id)}`)).json
      assert.deepEqual(detail.messages.map((message) => message.role), ['user'])
    })
  } finally {
    await lane.close()
  }
})

test('companion service, account and RoachSync actions follow the v1.0.5 contract', nativeOnly, async () => {
  const lane = await startFakeModelLane({ reply: () => 'ok' })
  try {
    await withRuntime(lane, async ({ bridge, tempRoot }) => {
      const service = await bridge('/api/companion/services/affect', { method: 'POST', body: { serviceName: 'roachnet_ollama', action: 'restart' } })
      assert.equal(service.status, 200)
      assert.equal(service.json.ok, true)
      assert.equal(service.json.serviceName, 'roachnet_ollama')
      assert.equal(service.json.action, 'restart')
      assert.equal((await bridge('/api/companion/services/affect', { method: 'POST', body: { serviceName: 'roachnet_ollama', action: 'explode' } })).status, 400)
      assert.equal((await bridge('/api/companion/services/affect', { method: 'POST', body: { serviceName: 'nope', action: 'start' } })).status, 404)

      const linked = await bridge('/api/companion/account/affect', { method: 'POST', body: { action: 'link', email: 'roach@example.test', displayName: 'Roach' } })
      assert.equal(linked.status, 200)
      assert.equal(linked.json.state.linked, true)
      assert.equal(linked.json.state.email, 'roach@example.test')
      assert.equal((await bridge('/api/companion/account')).json.linked, true)
      const unlinked = await bridge('/api/companion/account/affect', { method: 'POST', body: { action: 'unlink' } })
      assert.equal(unlinked.json.state.linked, false)
      assert.equal(unlinked.json.state.email, null)
      assert.equal((await bridge('/api/companion/account/affect', { method: 'POST', body: { action: 'hack' } })).status, 400)

      const enabled = await bridge('/api/companion/roachsync/affect', { method: 'POST', body: { action: 'enable' } })
      assert.equal(enabled.json.state.enabled, true)
      const folder = path.join(tempRoot, 'sync-folder')
      const moved = await bridge('/api/companion/roachsync/affect', { method: 'POST', body: { action: 'set-folder-path', folderPath: folder } })
      assert.equal(moved.json.state.folderPath, folder)
      assert.equal((await bridge('/api/companion/roachsync/affect', { method: 'POST', body: { action: 'set-folder-path', folderPath: path.join(tempRoot, 'missing') } })).status, 400)
      assert.equal((await bridge('/api/companion/roachsync')).json.enabled, true)
      const disabled = await bridge('/api/companion/roachsync/affect', { method: 'POST', body: { action: 'disable' } })
      assert.equal(disabled.json.state.enabled, false)
    })
  } finally {
    await lane.close()
  }
})
