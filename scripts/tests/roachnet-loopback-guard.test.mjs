import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import http from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  declaresJsonBody,
  isLoopbackHostname,
  isTrustedLoopbackHost,
  isTrustedLoopbackOrigin,
  loopbackRequestRejection,
} from '../lib/roachnet_loopback_guard.mjs'

// The loopback services must refuse what a web page can send them: a request
// under a rebound DNS name (Host), a cross-site request (Origin), and a body
// that is not declared as JSON (sent without a CORS preflight).

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const nativeBinary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const needsBinary = nativeBinary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

test('loopback names and literals pass; DNS names that only look like them do not', () => {
  for (const host of ['127.0.0.1', '127.1.2.3', 'localhost', 'LOCALHOST', '::1', '[::1]', '::ffff:127.0.0.1']) {
    assert.equal(isLoopbackHostname(host), true, host)
  }
  for (const host of ['127.example.net', '127.0.0.1.example.net', '127.0.0', '127.0.0.256', '0.0.0.0', '10.0.0.1', 'localhost.', 'roachnet.local', '']) {
    assert.equal(isLoopbackHostname(host), false, host)
  }
})

test('Host header checks', () => {
  for (const host of [undefined, '', '127.0.0.1:38111', 'localhost:38111', '[::1]:38111', '127.0.0.1']) {
    assert.equal(isTrustedLoopbackHost(host), true, String(host))
  }
  for (const host of ['127.example.net:38111', 'evil.example', 'evil.example:38111', '[::1]x', '127.0.0.1:port', 'a:b:c']) {
    assert.equal(isTrustedLoopbackHost(host), false, host)
  }
})

test('Origin header checks', () => {
  for (const origin of [undefined, 'http://127.0.0.1:38111', 'http://localhost:5173', 'http://[::1]:38111']) {
    assert.equal(isTrustedLoopbackOrigin(origin), true, String(origin))
  }
  for (const origin of ['null', 'https://evil.example', 'http://127.example.net:38111', 'file://', 'roachnet://app', '']) {
    assert.equal(isTrustedLoopbackOrigin(origin), false, origin)
  }
})

test('JSON content types', () => {
  assert.equal(declaresJsonBody({ 'content-type': 'application/json; charset=utf-8' }), true)
  assert.equal(declaresJsonBody({ 'content-type': 'application/merge-patch+json' }), true)
  for (const type of [undefined, 'text/plain', 'text/plain;charset=UTF-8', 'application/x-www-form-urlencoded', 'multipart/form-data']) {
    assert.equal(declaresJsonBody({ 'content-type': type }), false, String(type))
  }
  assert.equal(loopbackRequestRejection({ headers: { host: '127.0.0.1:1' } }), null)
  assert.equal(loopbackRequestRejection({ headers: { host: '127.example.net:1' } }).statusCode, 403)
  assert.equal(loopbackRequestRejection({ headers: { host: '127.0.0.1:1', origin: 'https://evil.example' } }).statusCode, 403)
})

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

test('the JavaScript setup service refuses rebound and cross-site requests', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'roachnet-setup-guard-'))
  const readyFile = path.join(root, 'ready.json')
  mkdirSync(path.join(root, 'home'), { recursive: true })
  const child = spawn(process.execPath, [path.join(repoRoot, 'scripts', 'run-roachnet-setup.mjs')], {
    cwd: repoRoot,
    env: {
      PATH: process.env.PATH,
      HOME: path.join(root, 'home'),
      ROACHNET_SETUP_NO_BROWSER: '1',
      ROACHNET_SETUP_READY_FILE: readyFile,
      ROACHNET_INSTALLER_CONFIG_PATH: path.join(root, 'installer-config.json'),
      ROACHNET_SETUP_WORK_ROOT: path.join(root, 'work'),
    },
    stdio: 'ignore',
  })
  try {
    const url = await waitFor(async () => existsSync(readyFile) && JSON.parse(readFileSync(readyFile, 'utf8')).url, child, 'setup service')
    const port = Number(new URL(url).port)
    // The setup service has no /api/health; its UI root answers instead.
    const own = `127.0.0.1:${port}`
    assert.equal((await send(port, { pathname: '/', headers: { host: own } })).status, 200)
    assert.equal((await send(port, { pathname: '/api/state', headers: { host: `127.example.net:${port}` } })).status, 403)
    assert.equal((await send(port, { method: 'POST', pathname: '/api/launch', headers: { host: own, origin: 'https://evil.example' } })).status, 403)
    assert.equal((await send(port, { method: 'POST', pathname: '/api/install', headers: { host: own, origin: 'null', 'content-type': 'application/json' }, body: '{}' })).status, 403)
    const plain = await send(port, { method: 'POST', pathname: '/api/launch', headers: { host: own, 'content-type': 'text/plain' }, body: '{"installedAppPath":"/System/Applications/Calculator.app"}' })
    assert.equal(plain.status, 415, plain.text)
    assert.equal(existsSync(path.join(root, 'installer-config.json')), false, 'nothing was saved')
  } finally {
    await stop(child)
    await rm(root, { recursive: true, force: true })
  }
})

async function startNativeApi(command, args, root) {
  const port = await freePort()
  const child = spawn(command, args, {
    cwd: repoRoot,
    env: {
      ...process.env,
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

test('the JavaScript native API refuses rebound and cross-site requests', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'roachnet-api-guard-js-'))
  const { child, port } = await startNativeApi(process.execPath, [path.join(repoRoot, 'scripts', 'run-roachnet-native-api.mjs')], root)
  try {
    await assertGuards(port, { postPath: '/api/roachclaw/tool-policy/evaluate', label: 'JS native API' })
  } finally {
    await stop(child)
    await rm(root, { recursive: true, force: true })
  }
})

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
