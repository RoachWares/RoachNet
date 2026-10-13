import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { readFileSync, readdirSync } from 'node:fs'
import { createServer } from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { mkdtemp, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { requestHttp } from '../lib/roachnet_http.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..', '..')
const binary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const needsBinary = binary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

async function resolveAvailablePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      server.close((error) => {
        if (error) reject(error)
        else resolve(address.port)
      })
    })
  })
}

async function requestJson(url, options = {}) {
  const response = await requestHttp(url, {
    method: options.method || 'GET',
    headers: {
      Accept: 'application/json',
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
    timeoutMs: 5_000,
  })
  const payload = JSON.parse(await response.text())
  assert.equal(response.ok, true, `${url} returned ${response.status}: ${JSON.stringify(payload)}`)
  return payload
}

async function waitForHealth(url, child, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`native API exited before health check: ${child.exitCode}`)
    }
    try {
      await requestJson(url)
      return
    } catch {
      await delay(50)
    }
  }
  throw new Error(`Timed out waiting for ${url}`)
}

async function stopNativeApi(child, env) {
  await new Promise((resolve) => {
    const stop = spawn(binary, ['--stop'], {
      cwd: repoRoot,
      env,
      stdio: 'ignore',
    })
    stop.once('close', resolve)
  })

  await new Promise((resolve) => {
    if (child.exitCode !== null) {
      resolve()
      return
    }
    const timer = setTimeout(() => {
      child.kill('SIGKILL')
      resolve()
    }, 5_000)
    child.once('exit', () => {
      clearTimeout(timer)
      resolve()
    })
  })
}

test('every macOS TimelineView stops when Reduce Motion is enabled', () => {
  const sourcesRoot = path.join(repoRoot, 'native', 'macos', 'Sources')
  const swiftFiles = []
  const pendingDirectories = [sourcesRoot]
  while (pendingDirectories.length > 0) {
    const directory = pendingDirectories.pop()
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name)
      if (entry.isDirectory()) pendingDirectories.push(entryPath)
      else if (entry.isFile() && entry.name.endsWith('.swift')) swiftFiles.push(entryPath)
    }
  }

  let timelineCount = 0
  let reduceMotionTimelineCount = 0
  const offenders = []
  for (const filePath of swiftFiles) {
    const source = readFileSync(filePath, 'utf8')
    const fileTimelineCount = source.match(/TimelineView\(/g)?.length || 0
    const fileReduceMotionCount = source.match(/TimelineView\(\.animation\([^\n]*paused:\s*reduceMotion\)/g)?.length || 0
    timelineCount += fileTimelineCount
    reduceMotionTimelineCount += fileReduceMotionCount
    if (fileTimelineCount !== fileReduceMotionCount) offenders.push(path.relative(repoRoot, filePath))
  }

  assert.equal(timelineCount >= 7, true, 'the release app should still contain the intentional timelines')
  assert.deepEqual(offenders, [], `TimelineView Reduce Motion gaps: ${offenders.join(', ')}`)
  assert.equal(reduceMotionTimelineCount, timelineCount)

  const aboutSource = readFileSync(
    path.join(sourcesRoot, 'RoachNetApp', 'RoachNetAboutView.swift'),
    'utf8'
  )
  assert.equal(
    (aboutSource.match(/\.onChange\(of: reduceMotion\)/g)?.length || 0) >= 3,
    true,
    'About animations must react when Reduce Motion changes while the window is open'
  )
  assert.equal(
    (aboutSource.match(/transaction\.disablesAnimations = true/g)?.length || 0) >= 3,
    true,
    'About animations must stop immediately without animating the reset'
  )
})

test('native status refresh coalesces duplicate provider and model probes', needsBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-performance-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const apiPort = await resolveAvailablePort()
  const ollamaPort = await resolveAvailablePort()
  const unusedOpenClawPort = await resolveAvailablePort()
  const counters = { version: 0, tags: 0, pullStarted: 0, pullFinished: 0 }
  let models = [{ name: 'qwen-test', size: 42 }]
  let signalPullStarted
  let releasePull
  let signalPullFinished
  const pullStarted = new Promise((resolve) => { signalPullStarted = resolve })
  const continuePull = new Promise((resolve) => { releasePull = resolve })
  const pullFinished = new Promise((resolve) => { signalPullFinished = resolve })

  const ollamaServer = createServer((request, response) => {
    if (request.url === '/api/version') {
      counters.version += 1
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end('{"version":"test"}')
      return
    }
    if (request.url === '/api/tags') {
      counters.tags += 1
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ models }))
      return
    }
    if (request.url === '/api/pull' && request.method === 'POST') {
      request.resume()
      request.once('end', async () => {
        counters.pullStarted += 1
        signalPullStarted()
        await continuePull
        models = [{ name: 'qwen-test', size: 42 }, { name: 'qwen-after-failed-pull', size: 84 }]
        counters.pullFinished += 1
        response.once('finish', signalPullFinished)
        response.writeHead(500, { 'content-type': 'application/json' })
        response.end('{"error":"connection ended after the model catalog changed"}')
      })
      return
    }
    response.writeHead(404, { 'content-type': 'application/json' })
    response.end('{"error":"not found"}')
  })
  await new Promise((resolve, reject) => {
    ollamaServer.once('error', reject)
    ollamaServer.listen(ollamaPort, '127.0.0.1', resolve)
  })

  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    OLLAMA_BASE_URL: `http://127.0.0.1:${ollamaPort}`,
    OPENCLAW_BASE_URL: `http://127.0.0.1:${unusedOpenClawPort}`,
    ROACHNET_RUNTIME_PROBE_CACHE_MS: '1000',
    ROACHNET_COMPANION_ENABLED: '0',
    HOST: '127.0.0.1',
    PORT: String(apiPort),
  }
  const child = spawn(binary, [], {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${apiPort}/api/health`, child)
    const startupDeadline = Date.now() + 5_000
    while (counters.version === 0 && Date.now() < startupDeadline) await delay(20)
    assert.equal(counters.version > 0, true, 'startup should warm the Ollama probe')

    await delay(1_050)
    counters.version = 0
    counters.tags = 0

    const statuses = await Promise.all(
      Array.from({ length: 8 }, () => requestJson(`http://127.0.0.1:${apiPort}/api/roachclaw/status`))
    )

    assert.equal(statuses.every((status) => status.ollama.available), true)
    assert.equal(statuses.every((status) => status.installedModels.includes('qwen-test')), true)
    assert.equal(counters.version, 1, 'concurrent status refreshes should share one reachability probe')
    assert.equal(counters.tags, 1, 'concurrent status refreshes should share one model-catalog request')

    await requestJson(`http://127.0.0.1:${apiPort}/api/roachclaw/apply`, {
      method: 'POST',
      body: { model: 'qwen-after-failed-pull' },
    })
    await pullStarted
    assert.equal(counters.pullStarted, 1, 'the fake Ollama pull should start')

    const duringPull = await requestJson(`http://127.0.0.1:${apiPort}/api/roachclaw/status`)
    assert.equal(duringPull.installedModels.includes('qwen-after-failed-pull'), false)

    releasePull()
    await pullFinished
    assert.equal(counters.pullFinished, 1, 'the fake Ollama pull should complete its failed response')
    const refreshDeadline = Date.now() + 300
    let refreshed = null
    do {
      refreshed = await requestJson(`http://127.0.0.1:${apiPort}/api/roachclaw/status`)
      if (refreshed.installedModels.includes('qwen-after-failed-pull')) break
      await delay(10)
    } while (Date.now() < refreshDeadline)
    assert.equal(
      refreshed.installedModels.includes('qwen-after-failed-pull'),
      true,
      'a failed or transport-ambiguous pull must invalidate the cached model catalog'
    )
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => ollamaServer.close(resolve))
  }
})
