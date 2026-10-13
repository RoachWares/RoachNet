import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import http from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// The loopback services must refuse what a web page can send them: a request
// under a rebound DNS name (Host), a cross-site request (Origin), and a body
// that is not declared as JSON (sent without a CORS preflight). The guard's
// own rules are unit-tested in native/macos/Tests/RoachNetRuntimeTests/LoopbackGuardTests.swift;
// these run the built runtime and setup service.

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const nativeBinary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const needsBinary = nativeBinary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

// node:http, so the Host header can be set to what a rebound page would send.
function send(port, { method = 'GET', pathname = '/api/health', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request({ host: '127.0.0.1', port, method, path: pathname, headers }, (response) => {
      let text = ''
      response.setEncoding('utf8')
      response.on('data', (chunk) => { text += chunk })
      response.on('end', () => resolve({ status: response.statusCode, text }))
    })
    request.on('error', reject)
    request.setTimeout(10_000, () => request.destroy(new Error(`timeout ${method} ${pathname}`)))
    request.end(body)
  })
}

async function waitFor(check, child, label) {
  const deadline = Date.now() + 20_000
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`${label} exited early (${child.exitCode})`)
    const value = await check().catch(() => null)
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  throw new Error(`${label} did not start`)
}

async function stop(child) {
  if (child.exitCode !== null) return
  child.kill('SIGTERM')
  await Promise.race([
    new Promise((resolve) => child.once('exit', resolve)),
    new Promise((resolve) => setTimeout(resolve, 4_000)),
  ])
  if (child.exitCode === null) child.kill('SIGKILL')
}

// Requests every loopback service must refuse, and the one it must accept.
async function assertGuards(port, { postPath, label }) {
  const own = `127.0.0.1:${port}`
  const json = { 'content-type': 'application/json' }
  assert.equal((await send(port, { pathname: '/api/health', headers: { host: own } })).status, 200, `${label}: plain loopback GET`)
  assert.equal((await send(port, { headers: { host: `127.example.net:${port}` } })).status, 403, `${label}: rebound 127.* name`)
  assert.equal((await send(port, { headers: { host: `evil.example:${port}` } })).status, 403, `${label}: rebound name`)
  const crossSite = await send(port, { method: 'POST', pathname: postPath, headers: { host: own, origin: 'https://evil.example' } })
  assert.equal(crossSite.status, 403, `${label}: cross-site POST with no body`)
  const sandboxed = await send(port, { method: 'POST', pathname: postPath, headers: { host: own, origin: 'null', ...json }, body: '{}' })
  assert.equal(sandboxed.status, 403, `${label}: Origin null`)
  const plain = await send(port, { method: 'POST', pathname: postPath, headers: { host: own, 'content-type': 'text/plain' }, body: '{"installPath":"/tmp/x"}' })
  assert.equal(plain.status, 415, `${label}: text/plain body: ${plain.text}`)
  const sameOrigin = await send(port, { method: 'GET', pathname: '/api/health', headers: { host: own, origin: `http://${own}` } })
  assert.equal(sameOrigin.status, 200, `${label}: same-origin page`)
}

async function startNativeApi(command, args, root, extraEnv = {}) {
  const port = await freePort()
  const child = spawn(command, args, {
    cwd: repoRoot,
    env: {
      ...process.env,
      ...extraEnv,
      HOME: root,
      HOST: '127.0.0.1',
      PORT: String(port),
      ROACHNET_STORAGE_PATH: path.join(root, 'storage'),
      ROACHNET_RUNTIME_STATE_ROOT: path.join(root, 'state'),
      ROACHNET_COMPANION_ENABLED: '0',
      ROACHNET_NO_BROWSER: '1',
    },
    stdio: 'ignore',
  })
  await waitFor(async () => (await send(port, { headers: { host: `127.0.0.1:${port}` } })).status === 200, child, 'native API')
  return { child, port }
}

test('the Swift runtime refuses rebound and cross-site requests', needsBinary, async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'roachnet-api-guard-swift-'))
  const { child, port } = await startNativeApi(nativeBinary, [], root)
  try {
    await assertGuards(port, { postPath: '/api/roachclaw/tool-policy/evaluate', label: 'Swift runtime' })
  } finally {
    await stop(child)
    await rm(root, { recursive: true, force: true })
  }
})

test('the Swift setup service refuses rebound and cross-site requests', needsBinary, async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'roachnet-setup-guard-swift-'))
  const readyFile = path.join(root, 'ready.json')
  const child = spawn(nativeBinary, ['--setup'], {
    env: { PATH: process.env.PATH, HOME: root, ROACHNET_SETUP_READY_FILE: readyFile, ROACHNET_SETUP_WORK_ROOT: path.join(root, 'work') },
    stdio: 'ignore',
  })
  try {
    const url = await waitFor(async () => existsSync(readyFile) && JSON.parse(readFileSync(readyFile, 'utf8')).url, child, 'Swift setup')
    await assertGuards(Number(new URL(url).port), { postPath: '/api/launch', label: 'Swift setup' })
  } finally {
    await stop(child)
    await rm(root, { recursive: true, force: true })
  }
})

// With ROACHNET_API_TOKEN set (RoachNet.app sets one per launch), another
// process on the Mac gets nothing without the token; health stays public.
async function assertTokenGate(port, token, label, serverInfoFile) {
  const own = `127.0.0.1:${port}`
  assert.equal((await send(port, { pathname: '/api/health', headers: { host: own } })).status, 200, `${label}: health`)
  assert.equal((await send(port, { pathname: '/api/system/info', headers: { host: own } })).status, 401, `${label}: no token`)
  assert.equal((await send(port, { pathname: '/api/system/info', headers: { host: own, authorization: 'Bearer wrong' } })).status, 401, `${label}: wrong token`)
  assert.equal((await send(port, { pathname: '/api/system/info', headers: { host: own, authorization: `Bearer ${token}` } })).status, 200, `${label}: launch token`)
  const minted = await send(port, { method: 'POST', pathname: '/api/roachclaw/tokens', headers: { host: own, authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify({ name: 'script', scopes: ['chat'] }) })
  assert.equal(minted.status, 200, `${label}: mint: ${minted.text}`)
  const raw = JSON.parse(minted.text).token
  // What matters here is that the gate let the chat token through.
  const chat = (await send(port, { pathname: '/api/companion/chat/sessions', headers: { host: own, authorization: `Bearer ${raw}` } })).status
  assert.ok(chat !== 401 && chat !== 403, `${label}: chat token on a chat route got ${chat}`)
  assert.equal((await send(port, { pathname: '/api/system/info', headers: { host: own, authorization: `Bearer ${raw}` } })).status, 403, `${label}: chat token elsewhere`)
  if (serverInfoFile) {
    const info = JSON.parse(readFileSync(serverInfoFile, 'utf8'))
    assert.equal(info.apiToken, token, `${label}: the app can read the token back`)
    assert.equal(statSync(serverInfoFile).mode & 0o077, 0, `${label}: server info is owner-only`)
  }
}

test('the Swift runtime requires its token when one is set', needsBinary, async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'roachnet-api-token-swift-'))
  const token = 'c'.repeat(64)
  const serverInfoFile = path.join(root, 'server-info.json')
  const { child, port } = await startNativeApi(nativeBinary, [], root, { ROACHNET_API_TOKEN: token, ROACHNET_SERVER_INFO_FILE: serverInfoFile })
  try {
    await assertTokenGate(port, token, 'Swift runtime', serverInfoFile)
  } finally {
    await stop(child)
    await rm(root, { recursive: true, force: true })
  }
})
