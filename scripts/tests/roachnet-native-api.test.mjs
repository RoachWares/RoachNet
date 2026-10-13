import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { createServer } from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { requestHttp } from '../lib/roachnet_http.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..', '..')
const macOSDittoTest = process.platform === 'darwin'
  ? {}
  : { skip: 'Requires macOS ditto archive semantics.' }

// The runtime contract is exercised against the native Swift runtime when
// ROACHNET_NATIVE_API_BINARY points at a built `roachnet-runtime`, and against
// the legacy Node launcher otherwise.
const nativeApiBinary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
function nativeApiCommand(extraArgs = []) {
  if (nativeApiBinary) {
    return [nativeApiBinary, extraArgs]
  }
  return [process.execPath, [path.join(repoRoot, 'scripts', 'run-roachnet-native-api.mjs'), ...extraArgs]]
}

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

async function resolveAvailablePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      server.close((error) => {
        if (error) {
          reject(error)
          return
        }
        resolve(address.port)
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
      ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
    timeoutMs: 5_000,
  })
  const payload = JSON.parse(await response.text())
  assert.equal(response.ok, true, `${url} returned ${response.status}: ${JSON.stringify(payload)}`)
  return payload
}

async function waitForHealth(url, child, timeoutMs = 20_000) {
  const startedAt = Date.now()
  while (Date.now() - startedAt < timeoutMs) {
    if (child.exitCode !== null) {
      throw new Error(`native API exited before health check: ${child.exitCode}`)
    }
    try {
      await requestJson(url)
      return
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 250))
    }
  }
  throw new Error(`Timed out waiting for ${url}`)
}

async function waitForPath(targetPath, child, timeoutMs = 20_000) {
  const startedAt = Date.now()
  while (Date.now() - startedAt < timeoutMs) {
    if (existsSync(targetPath)) {
      return
    }
    if (child.exitCode !== null) {
      throw new Error(`native API exited before writing ${targetPath}: ${child.exitCode}`)
    }
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
  throw new Error(`Timed out waiting for ${targetPath}`)
}

async function runTool(command, args, options = {}) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd || repoRoot,
      stdio: 'pipe',
    })
    let stderr = ''
    child.stderr?.on('data', (chunk) => {
      stderr += chunk.toString()
    })
    child.once('error', reject)
    child.once('close', (code) => {
      if (code === 0) {
        resolve()
      } else {
        reject(new Error(`${command} ${args.join(' ')} failed with ${code}: ${stderr}`))
      }
    })
  })
}

async function stopNativeApi(child, env) {
  await new Promise((resolve) => {
    const stop = spawn(...nativeApiCommand(['--stop']), {
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

async function createTestRoachSpeechPackZip(tempRoot, packID = 'test-roachvoice-pack') {
  const sourceRoot = path.join(tempRoot, packID)
  mkdirSync(path.join(sourceRoot, 'RoachVoice'), { recursive: true })
  writeFileSync(
    path.join(sourceRoot, 'RoachSpeechPack.json'),
    JSON.stringify(
      {
        packID,
        displayName: 'Test RoachVoice Pack',
        version: '1.0.5-test',
        kind: 'roachVoice',
        nativeFormat: 'coreML',
        features: ['customVoiceSynthesis'],
        noNetwork: true,
        noPackagedBinary: true,
        nativeInferenceReady: true,
        parityValidated: false,
      },
      null,
      2
    )
  )
  writeFileSync(path.join(sourceRoot, 'RoachVoice', 'placeholder.txt'), 'native test payload\n')
  const archivePath = path.join(tempRoot, `${packID}.zip`)
  await runTool('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', sourceRoot, archivePath])
  return archivePath
}

function startStaticFileServer(port, route, filePath) {
  const server = createServer((request, response) => {
    if (request.url === route) {
      const body = readFileSync(filePath)
      response.writeHead(200, {
        'content-type': 'application/zip',
        'content-length': body.byteLength,
      })
      response.end(body)
      return
    }

    response.writeHead(404, { 'content-type': 'application/json' })
    response.end('{"error":"not found"}')
  })

  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '127.0.0.1', () => resolve(server))
  })
}

function startStaticDirectoryServer(port, root) {
  const server = createServer((request, response) => {
    const requestUrl = new URL(request.url || '/', `http://127.0.0.1:${port}`)
    const relativePath = requestUrl.pathname.replace(/^\/+/, '')
    const filePath = path.resolve(root, relativePath)
    if (filePath.startsWith(path.resolve(root)) && existsSync(filePath)) {
      const body = readFileSync(filePath)
      response.writeHead(200, {
        'content-type': relativePath.endsWith('.json') ? 'application/json' : 'application/octet-stream',
        'content-length': body.byteLength,
      })
      response.end(body)
      return
    }

    response.writeHead(404, { 'content-type': 'application/json' })
    response.end('{"error":"not found"}')
  })

  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '127.0.0.1', () => resolve(server))
  })
}

function sha256FileSync(filePath) {
  return createHash('sha256').update(readFileSync(filePath)).digest('hex')
}

function splitFileIntoParts(filePath, outputRoot, routePrefix, partSize) {
  const buffer = readFileSync(filePath)
  const parts = []
  for (let offset = 0, index = 0; offset < buffer.length; offset += partSize, index += 1) {
    const part = buffer.subarray(offset, Math.min(offset + partSize, buffer.length))
    const filename = `part-${String(index + 1).padStart(3, '0')}.bin`
    const sha256 = createHash('sha256').update(part).digest('hex')
    const header = `ROACHNET-IA-CHUNK-v1 ${index} ${part.byteLength} ${sha256}\n`
    writeFileSync(path.join(outputRoot, filename), Buffer.concat([Buffer.from(header, 'utf8'), part]))
    parts.push({
      index,
      url: `${routePrefix}/${filename}`,
      offset,
      bytes: part.byteLength,
      sha256,
      encoding: 'roachnet-ia-chunk-v1',
      header,
      encodedBytes: Buffer.byteLength(header) + part.byteLength,
    })
  }
  return parts
}

function startReleaseServer(port) {
  const server = createServer((request, response) => {
    if (request.url === '/releases') {
      const body = JSON.stringify([
        {
          draft: false,
          prerelease: false,
          tag_name: 'v9.9.9',
          name: 'RoachNet 9.9.9',
          html_url: `http://127.0.0.1:${port}/release`,
          assets: [
            {
              name: 'RoachNet-Setup-macOS.dmg',
              browser_download_url: `http://127.0.0.1:${port}/RoachNet-Setup-macOS.dmg`,
            },
            {
              name: 'RoachNet-Setup-macOS.dmg.sha256',
              browser_download_url: `http://127.0.0.1:${port}/RoachNet-Setup-macOS.dmg.sha256`,
            },
          ],
        },
      ])
      response.writeHead(200, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      })
      response.end(body)
      return
    }

    // Real releases publish the installer with its checksum sidecar; the
    // update lane refuses installers it cannot verify.
    if (request.url === '/RoachNet-Setup-macOS.dmg.sha256') {
      const digest = createHash('sha256').update(Buffer.from('roachnet test installer payload')).digest('hex')
      const body = `${digest}  RoachNet-Setup-macOS.dmg\n`
      response.writeHead(200, { 'content-type': 'text/plain', 'content-length': Buffer.byteLength(body) })
      response.end(body)
      return
    }

    if (request.url === '/RoachNet-Setup-macOS.dmg') {
      const body = Buffer.from('roachnet test installer payload')
      response.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-length': body.byteLength,
      })
      response.end(body)
      return
    }

    response.writeHead(404, { 'content-type': 'application/json' })
    response.end('{"error":"not found"}')
  })

  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '127.0.0.1', () => resolve(server))
  })
}

// A stand-in for the GitHub Releases API. `mode` picks the installer body:
// 'broken' aborts mid-transfer, 'tampered' serves bytes that do not match the
// published sidecar, 'good' serves matching bytes. `sidecar: false` publishes
// the installer without its `.sha256` asset.
const fakeInstallerBytes = Buffer.from('roachnet installer payload for the update lane test')
const fakeInstallerSha256 = createHash('sha256').update(fakeInstallerBytes).digest('hex')

function startBrokenReleaseServer(port, { mode = 'broken', sidecar = true } = {}) {
  const server = createServer((request, response) => {
    if (request.url === '/releases') {
      const assets = [
        {
          name: 'RoachNet-Setup-macOS.dmg',
          browser_download_url: `http://127.0.0.1:${port}/broken.dmg`,
        },
      ]
      if (sidecar) {
        assets.push({
          name: 'RoachNet-Setup-macOS.dmg.sha256',
          browser_download_url: `http://127.0.0.1:${port}/broken.dmg.sha256`,
        })
      }
      const body = JSON.stringify([
        {
          draft: false,
          prerelease: false,
          tag_name: 'v9.9.9',
          name: 'RoachNet 9.9.9',
          html_url: `http://127.0.0.1:${port}/release`,
          assets,
        },
      ])
      response.writeHead(200, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      })
      response.end(body)
      return
    }

    if (request.url === '/broken.dmg.sha256') {
      const body = `${fakeInstallerSha256}  RoachNet-Setup-macOS.dmg\n`
      response.writeHead(200, { 'content-type': 'text/plain', 'content-length': Buffer.byteLength(body) })
      response.end(body)
      return
    }

    if (request.url === '/broken.dmg') {
      if (mode === 'broken') {
        response.writeHead(200, {
          'content-type': 'application/octet-stream',
          'content-length': '4096',
        })
        response.write(Buffer.from('partial roachnet installer payload'))
        response.destroy()
        return
      }
      const payload = mode === 'tampered' ? Buffer.from('a different installer than the sidecar names') : fakeInstallerBytes
      response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': payload.length })
      response.end(payload)
      return
    }

    response.writeHead(404, { 'content-type': 'application/json' })
    response.end('{"error":"not found"}')
  })

  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '127.0.0.1', () => resolve(server))
  })
}

function startSlowDownloadServer(port) {
  const server = createServer((request, response) => {
    if (request.url === '/slow.pmtiles') {
      response.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-length': String(1024 * 128),
      })
      let sent = 0
      const timer = setInterval(() => {
        if (sent >= 1024 * 128 || response.destroyed) {
          clearInterval(timer)
          if (!response.destroyed) response.end()
          return
        }
        sent += 1024
        response.write(Buffer.alloc(1024, 1))
      }, 25)
      response.once('close', () => clearInterval(timer))
      return
    }

    response.writeHead(404, { 'content-type': 'application/json' })
    response.end('{"error":"not found"}')
  })

  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '127.0.0.1', () => resolve(server))
  })
}

test('native API exposes app catalogs and companion payloads without the legacy WebUI runtime', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const companionPort = await resolveAvailablePort()
  const releasesPort = await resolveAvailablePort()
  const releaseServer = await startReleaseServer(releasesPort)
  const token = 'native-api-companion-test-token'
  const statePath = path.join(runtimeStateRoot, 'roachnet-native-api-state.json')
  const vaultFixture = path.join(storagePath, 'Vault', 'bootstrap-contract.md')
  mkdirSync(path.dirname(vaultFixture), { recursive: true })
  writeFileSync(vaultFixture, '# Bootstrap contract fixture\n')
  const reservedVaultRoot = path.join(storagePath, 'Vault')
  const legacyRoachClawTasksPath = path.join(storagePath, 'vault', 'roachclaw', 'tasks.json')
  const legacyProviderSecretPath = path.join(storagePath, 'vault', 'roachclaw', 'provider-secrets', 'openai.key')
  const legacyProviderSecret = 'shortkey'
  const legacyRoachClawTasks = JSON.stringify({ tasks: [{ id: 'legacy-task', title: 'Preserve legacy task', status: 'open' }] })
  mkdirSync(path.join(reservedVaultRoot, 'RoachTail'), { recursive: true })
  mkdirSync(path.join(reservedVaultRoot, 'RoachClaw', 'provider-secrets'), { recursive: true })
  mkdirSync(path.dirname(legacyRoachClawTasksPath), { recursive: true })
  writeFileSync(path.join(reservedVaultRoot, 'RoachTail', 'state.json'), '{"legacy":true}\n')
  writeFileSync(path.join(reservedVaultRoot, 'RoachClaw', 'tasks.json'), '{"tasks":[]}\n')
  writeFileSync(path.join(reservedVaultRoot, 'RoachClaw', 'provider-secrets', 'openai.key'), 'never-list-this\n')
  writeFileSync(legacyRoachClawTasksPath, legacyRoachClawTasks)
  mkdirSync(path.dirname(legacyProviderSecretPath), { recursive: true })
  writeFileSync(legacyProviderSecretPath, legacyProviderSecret)
  const processInfoPath = path.join(storagePath, 'logs', 'roachnet-runtime-processes.json')
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_COMPANION_ENABLED: '1',
    ROACHNET_COMPANION_HOST: '127.0.0.1',
    ROACHNET_COMPANION_PORT: String(companionPort),
    ROACHNET_COMPANION_TOKEN: token,
    ROACHNET_GITHUB_RELEASES_API_URL: `http://127.0.0.1:${releasesPort}/releases`,
    ROACHNET_RELEASES_URL: `http://127.0.0.1:${releasesPort}/release`,
    ROACHNET_OPEN_UPDATES: '0',
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)

    const services = await requestJson(`http://127.0.0.1:${port}/api/system/services`)
    assert.equal(services.some((service) => service.service_name === 'roachnet_ollama'), true)

    const maps = await requestJson(`http://127.0.0.1:${port}/api/maps/curated-collections`)
    assert.equal(Array.isArray(maps), true)
    assert.equal(maps.length > 0, true)
    assert.equal(Array.isArray(maps[0].resources), true)

    const categories = await requestJson(`http://127.0.0.1:${port}/api/zim/curated-categories`)
    assert.equal(categories.length > 0, true)
    assert.equal(Array.isArray(categories[0].tiers), true)

    const wikipedia = await requestJson(`http://127.0.0.1:${port}/api/zim/wikipedia`)
    assert.equal(wikipedia.options.length > 0, true)

    const latest = await requestJson(`http://127.0.0.1:${port}/api/system/latest-version?force=1`)
    assert.equal(latest.success, true)
    assert.equal(latest.updateAvailable, true)
    assert.equal(latest.latestVersion, '9.9.9')

    const agentStatus = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/agent/status`)
    assert.equal(agentStatus.runtime, 'roachclaw-native-agent')
    assert.equal(agentStatus.upstreamRuntimeDependency, 'none')
    assert.equal(agentStatus.references.hermesAgent.role, 'design-reference-only')
    assert.equal(agentStatus.skills.some((skill) => skill.id === 'app-context-router'), true)

    const legacyProviderState = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/cloud-providers`)
    const legacyOpenAI = legacyProviderState.providers.find((provider) => provider.id === 'openai')
    assert.equal(legacyOpenAI.configured, true)
    assert.equal(legacyOpenAI.configuredVia, 'legacy-local-secret-file')
    assert.equal(legacyOpenAI.tokenPrefix, null)
    assert.equal(JSON.stringify(legacyProviderState).includes(legacyProviderSecret), false)

    const agentRun = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/agent/run`, {
      method: 'POST',
      body: {
        prompt: 'Help with the active game.',
        execute: false,
        activeSurface: 'RoachArcade',
        enabledScopes: ['arcade'],
        context: {
          arcade: 'running game: Test Cartridge',
          vault: 'locked book note',
        },
      },
    })
    assert.equal(agentRun.runtime, 'roachclaw-native-agent')
    assert.equal(agentRun.executed, false)
    assert.match(agentRun.prompt.messages[1].content, /running game: Test Cartridge/)
    assert.doesNotMatch(agentRun.prompt.messages[1].content, /locked book note/)

    const update = await requestJson(`http://127.0.0.1:${port}/api/system/update`, { method: 'POST' })
    assert.equal(update.success, true)
    let updateStatus = null
    for (let attempt = 0; attempt < 40; attempt += 1) {
      updateStatus = await requestJson(`http://127.0.0.1:${port}/api/system/update/status`)
      if (updateStatus.stage === 'ready' || updateStatus.stage === 'error') {
        break
      }
      await new Promise((resolve) => setTimeout(resolve, 250))
    }
    assert.equal(updateStatus.stage, 'ready')
    assert.equal(existsSync(path.join(storagePath, 'updates', 'RoachNet-Setup-macOS.dmg')), true)
    assert.equal(existsSync(path.join(storagePath, 'updates', 'RoachNet-Setup-macOS.dmg.part')), false)

    await waitForPath(processInfoPath, child)
    const processInfo = JSON.parse(readFileSync(processInfoPath, 'utf8'))
    assert.equal(processInfo.companionUrl, `http://127.0.0.1:${companionPort}`)

    const bootstrap = await requestJson(`${processInfo.companionUrl}/api/companion/bootstrap`, { token })
    assert.equal(bootstrap.appName, 'RoachNet')
    assert.match(bootstrap.appsCatalogUrl, /^https:\/\/apps\.roachnet\.org\//)
    const companionRuntime = await requestJson(`${processInfo.companionUrl}/api/companion/runtime`, { token })
    const companionVault = await requestJson(`${processInfo.companionUrl}/api/companion/vault`, { token })
    assert.deepEqual(Object.keys(bootstrap.runtime).sort(), Object.keys(companionRuntime).sort())
    assert.deepEqual(Object.keys(bootstrap.vault).sort(), Object.keys(companionVault).sort())
    assert.equal(bootstrap.runtime.systemInfo.hardwareProfile.recommendedRuntime, 'native_local')
    assert.equal(typeof bootstrap.runtime.providers.providers, 'object')
    assert.notEqual(bootstrap.runtime.providers.providers, null)
    assert.equal(typeof bootstrap.runtime.roachClaw.label, 'string')
    assert.equal(bootstrap.runtime.roachClaw.playbook.schema, 'org.roachnet.roachclaw.playbook.v1')
    assert.equal(Array.isArray(bootstrap.runtime.services), true)
    assert.equal(Array.isArray(bootstrap.runtime.downloads), true)
    assert.equal(Array.isArray(bootstrap.runtime.installedModels), true)
    assert.equal(Array.isArray(bootstrap.runtime.issues), true)
    assert.equal(bootstrap.vault.vaultPath, path.join(storagePath, 'Vault'))
    assert.deepEqual(bootstrap.vault.knowledgeFiles, ['bootstrap-contract.md'])
    assert.equal(Array.isArray(bootstrap.vault.roachBrain), true)
    const ragFiles = await requestJson(`http://127.0.0.1:${port}/api/rag/files`)
    assert.deepEqual(ragFiles.files, ['bootstrap-contract.md'])
    for (let index = 0; index < 100; index += 1) {
      writeFileSync(path.join(reservedVaultRoot, 'RoachClaw', `internal-${index}.json`), '{}\n')
    }
    writeFileSync(path.join(reservedVaultRoot, 'user-note.md'), '# User-facing vault fixture\n')
    const paginatedCompanionVault = await requestJson(`${processInfo.companionUrl}/api/companion/vault`, { token })
    const paginatedRagFiles = await requestJson(`http://127.0.0.1:${port}/api/rag/files`)
    assert.deepEqual(paginatedCompanionVault.knowledgeFiles, ['bootstrap-contract.md', 'user-note.md'])
    assert.deepEqual(paginatedRagFiles.files, ['bootstrap-contract.md', 'user-note.md'])
    assert.equal(companionRuntime.systemInfo.hardwareProfile.recommendedRuntime, 'native_local')
    assert.equal(Array.isArray(companionRuntime.services), true)
    assert.equal(Array.isArray(companionRuntime.downloads), true)
    assert.equal(Array.isArray(companionRuntime.installedModels), true)
    assert.equal(companionRuntime.roachClaw.playbook.schema, 'org.roachnet.roachclaw.playbook.v1')
    assert.equal(companionRuntime.roachClaw.playbook.source, 'roachnet-native')
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-cookbook'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-quant-aware-fit'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-secure-actions'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-provider-diagnostics'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-agent-run-monitor'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-contextual-side-panel'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-vault-navigator'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-agent-activity-monitor'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-orchestration-dashboard'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-session-board'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-model-bench'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-document-lab'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-theme-studio'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-assistant-crew'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-backup-restore'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-user-cloud-provider-keys'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-workspace-browser'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-user-time-context'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-cookbook-serve-lifecycle'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-url-security'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-scoped-tool-bridge'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-tls-overrides'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-upload-limits'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachbrain-memory-provider'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-provider-oauth'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachbrain-embedding-lanes'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-tool-policy'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-service-health'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-streaming-markdown'), true)
    assert.equal(companionRuntime.roachClaw.playbook.capabilities.includes('roachclaw-migration-document-tools'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceSource.repository, 'https://github.com/pewdiepie-archdaemon/odysseus')
    assert.equal(companionRuntime.roachClaw.playbook.referenceSource.commit, 'd9ebdd6fbba31b5f3c2cbae90f650f183958660e')
    assert.equal(companionRuntime.roachClaw.playbook.referenceSource.latestSeenCommit, 'd9ebdd6fbba31b5f3c2cbae90f650f183958660e')
    assert.equal(companionRuntime.roachClaw.playbook.referenceSource.sourceKind, 'github-upstream')
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.schema, 'org.roachnet.roachclaw.github-reference-inventory.v1')
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.repository, 'https://github.com/pewdiepie-archdaemon/odysseus')
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.commit, 'd9ebdd6fbba31b5f3c2cbae90f650f183958660e')
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.observedFileCount, 1141)
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.functionalFileCount, 416)
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.coverageGroups.length, 8)
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.coverageGroups.some((group) => group.id === 'routes' && group.fileCount === 54), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.coverageGroups.some((group) => group.id === 'source' && group.fileCount === 108), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.coverageGroups.some((group) => group.id === 'mcp-servers' && group.fileCount === 5), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.coverageGroups.some((group) => group.id === 'services' && group.fileCount === 40), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.coverageGroups.some((group) => group.id === 'scripts' && group.fileCount === 43), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceInventory.coverageGroups.some((group) => group.id === 'static-js' && group.fileCount === 152), true)
    assert.match(companionRuntime.roachClaw.playbook.referenceInventory.nonShippingPolicy, /reference material only/)
    assert.equal(companionRuntime.roachClaw.playbook.coverage.schema, 'org.roachnet.roachclaw.reference-coverage.v1')
    assert.deepEqual(companionRuntime.roachClaw.playbook.coverage.missingFamilies, [])
    assert.equal(companionRuntime.roachClaw.playbook.coverage.posture, 'native-rewrite-no-python-webui-dependency')
    assert.equal(companionRuntime.roachClaw.playbook.coverage.featureGroupCount >= 39, true)
    assert.equal(companionRuntime.roachClaw.playbook.coverage.moduleCount >= 90, true)
    assert.equal(companionRuntime.roachClaw.playbook.coverage.repository, 'https://github.com/pewdiepie-archdaemon/odysseus')
    assert.equal(companionRuntime.roachClaw.playbook.coverage.sourceKind, 'github-upstream')
    assert.equal(companionRuntime.roachClaw.playbook.coverage.observedFileCount, 1141)
    assert.equal(companionRuntime.roachClaw.playbook.coverage.functionalFileCount, 416)
    assert.equal(companionRuntime.roachClaw.playbook.coverage.inventoryGroupCount, 8)
    assert.equal(companionRuntime.roachClaw.playbook.coverage.inventoryCoverageMode, 'full-github-functional-surface')
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'cookbook'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'workspace-browser'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'migration-document-tools'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'time-context'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'inbox-calendar'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'diagnostics-control'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'service-health'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'agent-monitor'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'orchestration'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'session-board'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'model-bench'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'theme-studio'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'assistant-crew'), true)
    assert.equal(companionRuntime.roachClaw.playbook.lanes.some((lane) => lane.id === 'backup-restore'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'email'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'mobile'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'security'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'diagnostics'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'webhooks-integrations'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'orchestration'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'session-board'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'model-bench'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'theme-studio'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'assistant-crew'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'backup-restore'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'workspace-browser'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'user-time'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'memory-provider'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'embedding-lanes'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'provider-security'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'tool-policy'), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'diagnostics' && group.capabilities.includes('service-health-rollup')), true)
    assert.equal(companionRuntime.roachClaw.playbook.featureGroups.some((group) => group.id === 'font-emoji-assets'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'routes/webhook_routes.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'routes/assistant_routes.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'routes/api_token_routes.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'routes/codex_routes.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'routes/workspace_routes.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'routes/stt_routes.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'routes/tts_routes.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/action_intents.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/agent_runs.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/agent_tools/filesystem_tools.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/service_health.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/cookbook_serve_lifecycle.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/event_bus.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/embedding_lanes.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/url_security.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/url_safety.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/user_time.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/pdf_runtime.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/settings.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/settings_scrub.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'src/tool_policy.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'services/hwfit/fit.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'services/faces/__init__.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'services/hwfit/image_models.py'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'static/js/compare/scoreboard.js'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'static/js/emailLibrary.js'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'static/js/cookbookProgressSignal.js'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'static/js/workspace.js'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'static/js/streamingSegmenter.js'), true)
    assert.equal(companionRuntime.roachClaw.playbook.referenceModules.some((module) => module.source === 'static/js/streamingRenderer.js'), true)
    assert.equal(companionRuntime.roachClaw.operations.schema, 'org.roachnet.roachclaw.operations.v1')
    assert.equal(companionRuntime.roachClaw.operations.diagnostics.probes.some((probe) => probe.id === 'roachclaw-native-agent'), true)
    assert.equal(companionRuntime.roachClaw.operations.contacts.scopes.includes('reply-recipient-context'), true)
    assert.equal(companionRuntime.roachClaw.operations.hooks.endpoints.some((endpoint) => endpoint.path === '/api/roachclaw/agent/run'), true)
    assert.equal(companionRuntime.roachClaw.operations.jobs.scheduler.status, 'local-queue')
    assert.equal(companionRuntime.roachClaw.operations.reports.templates.includes('diagnostics-report'), true)
    assert.equal(companionRuntime.roachClaw.operations.commandDeck.status, 'ready')
    assert.equal(companionRuntime.roachClaw.operations.commandDeck.hotkey, 'Ctrl-Cmd-R')
    assert.equal(companionRuntime.roachClaw.operations.commandDeck.route, 'roachnet://command')
    assert.equal(companionRuntime.roachClaw.operations.contextRail.status, 'empty')
    assert.equal(companionRuntime.roachClaw.operations.vaultNavigator.status, 'empty')
    assert.equal(companionRuntime.roachClaw.operations.agentMonitor.status, 'idle')
    assert.equal(companionRuntime.roachClaw.operations.orchestrationDashboard.status, 'coordinating')
    assert.equal(companionRuntime.roachClaw.operations.workspaceBrowser.status, 'ready')
    assert.equal(companionRuntime.roachClaw.operations.userTime.status, 'system-default')
    assert.equal(companionRuntime.roachClaw.operations.cookbookServeLifecycle.status, 'idle')
    assert.equal(companionRuntime.roachClaw.operations.scopedToolBridge.status, 'ready')
    assert.equal(companionRuntime.roachClaw.operations.tlsOverrides.status, 'default-trust')
    assert.equal(companionRuntime.roachClaw.operations.uploadLimits.status, 'enforced')
    assert.equal(companionRuntime.roachClaw.operations.migrationDocumentTools.status, 'native-state')
    assert.equal(companionRuntime.roachClaw.operations.migrationDocumentTools.summaryItems.includes('Office docs become vault docs'), true)
    assert.equal(companionRuntime.roachClaw.operations.memoryProvider.status, 'native-provider')
    assert.equal(companionRuntime.roachClaw.operations.providerOAuth.status, 'idle')
    assert.equal(companionRuntime.roachClaw.operations.embeddingLanes.status, 'healthy')
    assert.equal(companionRuntime.roachClaw.operations.embeddingLanes.count, 2)
    assert.equal(companionRuntime.roachClaw.operations.toolPolicy.status, 'enforced')
    assert.equal(['ok', 'degraded', 'down'].includes(companionRuntime.roachClaw.operations.serviceHealth.status), true)
    assert.equal(companionRuntime.roachClaw.operations.serviceHealth.report.source, 'github-upstream-service-health-native-rewrite')
    assert.equal(companionRuntime.roachClaw.operations.serviceHealth.report.services.some((service) => service.name === 'intake-policy' && service.status === 'ok'), true)
    assert.equal(companionRuntime.roachClaw.operations.adminRecovery.remoteAccess, false)
    const reportOps = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/operations/reports`)
    assert.equal(reportOps.formats.includes('markdown'), true)
    const commandDeckOps = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/operations/commandDeck`)
    assert.equal(commandDeckOps.actions.includes('Search commands'), true)
    assert.equal(commandDeckOps.summaryItems.includes('0 armed tools'), true)
    const workspaceBrowse = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/workspace/browse?path=${encodeURIComponent(storagePath)}`)
    assert.equal(workspaceBrowse.schema, 'org.roachnet.roachclaw.workspace-browser.v1')
    assert.equal(workspaceBrowse.policy.includes('directories-only'), true)
    const userTime = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/user-time`, {
      method: 'POST',
      body: { timeZoneName: 'America/Indiana/Indianapolis', utcOffsetMinutes: -240 },
    })
    assert.equal(userTime.utcOffset, '-04:00')
    assert.match(userTime.promptContext, /America\/Indiana\/Indianapolis/)
    const cookbookSchedule = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/cookbook/schedules`, {
      method: 'POST',
      body: { model: 'qwen2.5-coder:1.5b', days: ['monday'], durationMinutes: 45, mirrorToCalendar: true },
    })
    assert.equal(cookbookSchedule.schedules[0].model, 'qwen2.5-coder:1.5b')
    assert.equal(cookbookSchedule.active, 1)
    const progressSignal = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/cookbook/progress-signal`, {
      method: 'POST',
      body: { lastPercent: 42, snapshot: 'compile step still moving' },
    })
    assert.equal(progressSignal.mode, 'snapshot-tail')
    assert.match(progressSignal.signal, /compile step/)
    const scopedTools = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/scoped-tools/capabilities`)
    assert.equal(scopedTools.localOnly, true)
    assert.equal(scopedTools.scopes.includes('memory:write'), true)
    assert.equal(scopedTools.scopes.includes('migration:read'), true)
    assert.equal(scopedTools.endpoints.some((endpoint) => endpoint.path === '/api/roachclaw/diagnostics/services'), true)
    assert.equal(scopedTools.endpoints.some((endpoint) => endpoint.path === '/api/roachclaw/migration-document-tools'), true)
    const serviceHealth = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/diagnostics/services`)
    assert.equal(serviceHealth.schema, 'org.roachnet.roachclaw.service-health.v1')
    assert.equal(serviceHealth.upstreamModule, 'src/service_health.py')
    assert.equal(serviceHealth.budgets.secretPolicy, 'redacted-endpoints-no-raw-exceptions')
    assert.equal(serviceHealth.services.some((service) => service.name === 'roachclaw-native-agent' && service.status === 'ok'), true)
    assert.equal(JSON.stringify(serviceHealth).includes('sk-'), false)
    const uploadLimits = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/security/upload-limits`)
    assert.equal(uploadLimits.schema, 'org.roachnet.roachclaw.upload-limits.v1')
    assert.equal(uploadLimits.source, 'github-upstream-upload-limits-native-rewrite')
    assert.equal(uploadLimits.upstreamModule, 'src/upload_limits.py')
    assert.equal(uploadLimits.policy, 'centralized-hard-caps-public-413-clean-partial-files')
    assert.equal(uploadLimits.limits.some((limit) => limit.id === 'json-body'), true)
    assert.equal(uploadLimits.limits.some((limit) => limit.id === 'chat-upload' && limit.bytes === 10 * 1024 * 1024), true)
    assert.equal(uploadLimits.limits.some((limit) => limit.id === 'gallery-upload' && limit.bytes === 100 * 1024 * 1024), true)
    assert.equal(uploadLimits.limits.some((limit) => limit.id === 'speech-audio' && limit.env === 'ROACHNET_STT_AUDIO_MAX_BYTES'), true)
    assert.equal(uploadLimits.limits.some((limit) => limit.id === 'calendar-import' && limit.formatted === '10 MB'), true)
    assert.equal(uploadLimits.laneCounts['vault-gallery'], 2)
    assert.equal(uploadLimits.summaryItems.includes('Chat attachment: 10 MB'), true)
    const migrationDocumentTools = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/migration-document-tools`)
    assert.equal(migrationDocumentTools.schema, 'org.roachnet.roachclaw.migration-document-tools.v1')
    assert.equal(migrationDocumentTools.upstreamModules.includes('src/agent_tools/document_tools.py'), true)
    assert.equal(migrationDocumentTools.documentTools.supportedFormats.includes('docx'), true)
    assert.equal(migrationDocumentTools.validators.remoteHost, 'host-or-user-at-host-only-no-ssh-options')
    assert.equal(migrationDocumentTools.cookbookOutput.errorTailLines, 50)
    assert.equal(JSON.stringify(migrationDocumentTools).includes('Odysseus'), false)
    const pemPath = path.join(storagePath, 'test-provider-ca.pem')
    writeFileSync(pemPath, '-----BEGIN CERTIFICATE-----\\nroachnet-test\\n-----END CERTIFICATE-----\\n')
    const tlsOverride = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/security/tls-overrides`, {
      method: 'POST',
      body: { bundlePath: pemPath },
    })
    assert.equal(tlsOverride.valid, true)
    assert.equal(tlsOverride.insecureDisableAllowed, false)
    assert.equal(JSON.stringify(tlsOverride).includes(pemPath), false)
    const memoryProvider = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/memory-provider`, {
      method: 'POST',
      body: { id: 'external-lab', displayName: 'External Lab Memory', enabled: false, tools: ['recall'] },
    })
    assert.equal(memoryProvider.providers.some((provider) => provider.id === 'roachbrain-native' && provider.enabled), true)
    assert.equal(memoryProvider.providers.some((provider) => provider.id === 'external-lab' && provider.enabled === false), true)
    const oauthFlow = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/provider-oauth`, {
      method: 'POST',
      body: { provider: 'mcp-lab', serverUrl: 'https://mcp.example.com', scopes: ['tools'], authUrl: 'https://mcp.example.com/authorize?secret=do-not-export' },
    })
    assert.equal(oauthFlow.flows[0].provider, 'mcp-lab')
    assert.equal(oauthFlow.flows[0].authUrl, '[redacted-user-auth-url]')
    assert.equal(JSON.stringify(oauthFlow).includes('do-not-export'), false)
    const embeddingLanes = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/embedding-lanes`)
    assert.equal(embeddingLanes.schema, 'org.roachnet.roachbrain.embedding-lanes.v1')
    assert.equal(embeddingLanes.pythonRuntimeDependency, 'none')
    assert.equal(embeddingLanes.lanes.some((lane) => lane.id === 'custom'), true)
    assert.equal(embeddingLanes.lanes.some((lane) => lane.id === 'local' && lane.dimension === 384), true)
    assert.equal(embeddingLanes.resetSafety.destructiveResetAllowed, false)
    const configuredEmbeddingLanes = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/embedding-lanes`, {
      method: 'POST',
      body: { url: 'https://embeddings.example.com/v1?key=do-not-export', model: 'nomic-embed-text', dimension: 768, reset: true },
    })
    const configuredCustomLane = configuredEmbeddingLanes.lanes.find((lane) => lane.id === 'custom')
    assert.equal(configuredCustomLane.dimension, 768)
    assert.equal(configuredCustomLane.health.status, 'healthy')
    assert.equal(configuredCustomLane.endpoint, '[user-owned-endpoint-redacted]')
    assert.equal(JSON.stringify(configuredEmbeddingLanes).includes('do-not-export'), false)
    const toolPolicy = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/tool-policy/evaluate`, {
      method: 'POST',
      body: { lastUserMessage: 'GUIDE-ONLY MODE. DO NOT USE TOOLS.', disabledTools: ['web_search'] },
    })
    assert.equal(toolPolicy.mode, 'guide_only')
    assert.equal(toolPolicy.blockAllToolCalls, true)
    assert.equal(toolPolicy.disableMcp, true)
    assert.equal(toolPolicy.disabledTools.includes('bash'), true)
    assert.equal(toolPolicy.hiddenTools.includes('bash'), true)
    assert.equal(toolPolicy.disabledTools.includes('web_search'), true)
    const contacts = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/contacts`, {
      method: 'POST',
      body: { name: 'Roach Support', email: 'support@roachnet.local', tags: ['support', 'local'] },
    })
    assert.equal(contacts.contacts.length, 1)
    assert.equal(contacts.contacts[0].name, 'Roach Support')
    const legacyTasks = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/tasks`)
    assert.equal(legacyTasks.tasks.length, 1)
    assert.equal(legacyTasks.tasks[0].id, 'legacy-task')
    const tasks = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/tasks`, {
      method: 'POST',
      body: { title: 'Finish native feature port', priority: 'high', dueAt: '2026-06-02' },
    })
    assert.equal(tasks.tasks.length, 2)
    assert.equal(tasks.tasks[0].status, 'open')
    assert.equal(readFileSync(legacyRoachClawTasksPath, 'utf8'), legacyRoachClawTasks)
    const runtimeTasks = JSON.parse(readFileSync(path.join(runtimeStateRoot, 'roachclaw', 'tasks.json'), 'utf8'))
    assert.equal(runtimeTasks.tasks.length, 2)
    assert.equal(runtimeTasks.tasks.some((task) => task.id === 'legacy-task'), true)
    const calendar = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/calendar`, {
      method: 'POST',
      body: { title: 'Release review', startAt: '2026-06-02T13:00:00-04:00', location: 'RoachNet' },
    })
    assert.equal(calendar.events[0].title, 'Release review')
    const reports = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/reports`, {
      method: 'POST',
      body: { title: 'Diagnostics brief', kind: 'diagnostics-report', formats: ['markdown', 'json'] },
    })
    assert.equal(reports.reports[0].kind, 'diagnostics-report')
    const memory = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/memories`, {
      method: 'POST',
      body: { title: 'Useful habit', content: 'Check local runtime state before claiming release readiness.', tags: ['release'] },
    })
    assert.equal(memory.memories[0].title, 'Useful habit')
    const skill = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/skills`, {
      method: 'POST',
      body: { name: 'Release gate sweep', category: 'release', body: 'Run native, iOS, site, and diff gates before shipping.' },
    })
    assert.equal(skill.skills[0].category, 'release')
    const editorDraft = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/editor-drafts`, {
      method: 'POST',
      body: { title: 'RoachClaw note', format: 'markdown', body: '# RoachClaw\nKeep the stack local.' },
    })
    assert.equal(editorDraft.drafts[0].format, 'markdown')
    const searchCache = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/search-cache`, {
      method: 'POST',
      body: { query: 'local-first release checklist', provider: 'vault', sources: ['README.md', 'MEMORY.MD'] },
    })
    assert.equal(searchCache.entries[0].sourceCount, 2)
    const gallery = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/gallery`, {
      method: 'POST',
      body: { title: 'Vault cover', kind: 'image', path: '/tmp/vault-cover.png', tags: ['vault'] },
    })
    assert.equal(gallery.assets[0].title, 'Vault cover')
    const webhook = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/webhooks`, {
      method: 'POST',
      body: { name: 'Local build hook', secret: 'do-not-store-me', target: 'release-check' },
    })
    assert.equal(webhook.webhooks[0].isActive, true)
    assert.equal(webhook.webhooks[0].secretDigest.length, 64)
    assert.equal(webhook.webhooks[0].secretSalt.length, 32, 'each webhook secret gets its own salt')
    assert.equal(webhook.webhooks[0].secretDigestAlgorithm, 'hmac-sha256-salted-v1')
    assert.notEqual(webhook.webhooks[0].secretDigest, createHash('sha256').update('do-not-store-me').digest('hex'), 'not a bare SHA-256')
    assert.equal(webhook.webhooks[0].secretHint, '…me')
    assert.equal(JSON.stringify(webhook).includes('do-not-store-me'), false)
    const trackedRun = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/agent-runs`, {
      method: 'POST',
      body: { sessionId: 'session-test', title: 'Detached local run', status: 'running', model: 'qwen2.5-coder:1.5b', events: ['start', 'tool:read_file'] },
    })
    assert.equal(trackedRun.runs[0].status, 'running')
    assert.equal(trackedRun.runs[0].eventCount, 2)
    const compaction = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/context-compactions`, {
      method: 'POST',
      body: { sessionId: 'session-test', title: 'Release context', summary: 'Keep the native conversion plan and open gates.', turnsSummarized: 8, tokensBefore: 9000, tokensAfter: 1200 },
    })
    assert.equal(compaction.compactions[0].turnsSummarized, 8)
    const toolIndex = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/tool-index`, {
      method: 'POST',
      body: { name: 'vault_context', category: 'vault', description: 'Reads local vault excerpts for RoachClaw.', alwaysAvailable: true, tags: ['vault', 'context'] },
    })
    assert.equal(toolIndex.tools[0].alwaysAvailable, true)
    const eventCounter = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/events`, {
      method: 'POST',
      body: { id: 'event-message-sent', name: 'message.sent', owner: 'local-owner', increment: 1, actions: ['update-context'] },
    })
    assert.equal(eventCounter.events[0].count, 1)
    const mailMessage = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/mail/messages`, {
      method: 'POST',
      body: { from: 'builder@roachnet.local', to: ['support@roachnet.local'], subject: 'Native lane', preview: 'Mail is local state now.' },
    })
    assert.equal(mailMessage.messages[0].subject, 'Native lane')
    const mailDraft = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/mail/drafts`, {
      method: 'POST',
      body: { to: ['support@roachnet.local'], subject: 'Reply draft', body: 'Ship the native route.' },
    })
    assert.equal(mailDraft.drafts[0].status, 'draft')
    const preset = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/presets`, {
      method: 'POST',
      body: { name: 'Release reviewer', systemPrompt: 'Be direct. Find release blockers.', temperature: 0.2 },
    })
    assert.equal(preset.templates[0].name, 'Release reviewer')
    const signature = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/signatures`, {
      method: 'POST',
      body: { name: 'RoachWares', dataUrl: 'data:image/png;base64,cm9hY2huZXQ=' },
    })
    assert.equal(signature.signatures[0].name, 'RoachWares')
    const tokenResult = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/tokens`, {
      method: 'POST',
      body: { name: 'Local test token', scopes: ['chat', 'vault'] },
    })
    assert.match(tokenResult.token, /^rn_/)
    assert.equal(JSON.stringify(tokenResult).includes('tokenHash'), false)
    const tokenStore = JSON.parse(readFileSync(path.join(runtimeStateRoot, 'roachclaw', 'api-tokens.json'), 'utf8'))
    assert.equal(tokenStore.tokens[0].tokenHash.length, 64)
    assert.equal(JSON.stringify(tokenStore).includes(tokenResult.token), false)
    const providerResult = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/cloud-providers`, {
      method: 'POST',
      body: { provider: 'openai', key: 'sk-test-roachnet-local-provider-key', scopes: ['chat', 'models'] },
    })
    assert.equal(providerResult.success, true)
    assert.equal(providerResult.provider.id, 'openai')
    assert.equal(providerResult.provider.configured, true)
    assert.equal(providerResult.provider.configuredVia, 'runtime-local-secret-file')
    assert.equal(JSON.stringify(providerResult).includes('sk-test-roachnet-local-provider-key'), false)
    assert.equal(JSON.stringify(providerResult).includes('keyHash'), false)
    const providerStore = JSON.parse(readFileSync(path.join(runtimeStateRoot, 'roachclaw', 'cloud-provider-keys.json'), 'utf8'))
    assert.equal(providerStore.providers[0].keyHash.length, 64)
    assert.equal(JSON.stringify(providerStore).includes('sk-test-roachnet-local-provider-key'), false)
    const rejectedProviderResponse = await requestHttp(`http://127.0.0.1:${port}/api/roachclaw/cloud-providers`, {
      method: 'POST',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: JSON.stringify({ provider: 'openrouter', key: 'sk-test-local-private-url', baseUrl: 'http://127.0.0.1:9999/v1' }),
      timeoutMs: 5_000,
    })
    assert.equal(rejectedProviderResponse.ok, false)
    assert.equal(rejectedProviderResponse.status, 400)
    const providerSecretPath = path.join(runtimeStateRoot, 'roachclaw', 'provider-secrets', 'openai.key')
    assert.equal(readFileSync(providerSecretPath, 'utf8'), 'sk-test-roachnet-local-provider-key')
    const aiProviders = await requestJson(`http://127.0.0.1:${port}/api/system/ai/providers`)
    assert.equal(aiProviders.cloudProviders.providers.some((provider) => provider.id === 'openai' && provider.configured), true)
    assert.equal(JSON.stringify(aiProviders).includes('sk-test-roachnet-local-provider-key'), false)
    const backup = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/backups`, {
      method: 'POST',
      body: { title: 'Native feature backup' },
    })
    assert.equal(backup.success, true)
    assert.equal(backup.snapshots.snapshots[0].title, 'Native feature backup')
    const exportPayload = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/export`)
    assert.equal(exportPayload.schema, 'org.roachnet.roachclaw.export.v1')
    assert.equal(exportPayload.mail.messages.length, 1)
    assert.equal(exportPayload.agentRuns.length, 1)
    assert.equal(exportPayload.contextCompactions.length, 1)
    assert.equal(exportPayload.cloudProviders.some((provider) => provider.id === 'openai' && provider.configured), true)
    assert.equal(JSON.stringify(exportPayload).includes('sk-test-roachnet-local-provider-key'), false)
    assert.equal(exportPayload.scopedToolBridge.scopes.includes('documents:write'), true)
    assert.equal(exportPayload.tlsOverrides.bundlePath, '[local-path-redacted]')
    assert.equal(JSON.stringify(exportPayload.providerOAuth).includes('do-not-export'), false)
    assert.equal(exportPayload.embeddingLanes.lanes.some((lane) => lane.id === 'custom' && lane.fingerprint), true)
    assert.equal(JSON.stringify(exportPayload.embeddingLanes).includes('do-not-export'), false)
    assert.equal(exportPayload.toolPolicy.mode, 'normal')
    const updatedOps = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/operations`)
    assert.equal(updatedOps.contacts.recordCount, 1)
    assert.equal(updatedOps.notesTasks.count, 2)
    assert.equal(updatedOps.calendar.count, 1)
    assert.equal(updatedOps.reports.count, 1)
    assert.equal(updatedOps.memories.count, 1)
    assert.equal(updatedOps.skills.count, 1)
    assert.equal(updatedOps.editorDrafts.open, 1)
    assert.equal(updatedOps.searchCache.count, 1)
    assert.equal(updatedOps.gallery.count, 1)
    assert.equal(updatedOps.webhooks.active, 1)
    assert.equal(JSON.stringify(updatedOps.webhooks).includes('do-not-store-me'), false)
    assert.equal(updatedOps.agentRuns.active, 1)
    assert.equal(updatedOps.contextCompactions.count, 1)
    assert.equal(updatedOps.toolIndex.active, 1)
    assert.equal(updatedOps.events.count, 1)
    assert.equal(updatedOps.commandDeck.count, 4)
    assert.equal(updatedOps.commandDeck.active, 1)
    assert.equal(updatedOps.commandDeck.summaryItems.includes('1 armed tools'), true)
    assert.equal(updatedOps.contextRail.hotkey, 'Cmd-Shift-C')
    assert.equal(updatedOps.contextRail.count, 4)
    assert.equal(updatedOps.vaultNavigator.route, 'roachnet://vault')
    assert.equal(updatedOps.vaultNavigator.count, 4)
    assert.equal(updatedOps.agentMonitor.active, 1)
    assert.equal(updatedOps.agentMonitor.summaryItems.includes('1 running'), true)
    assert.equal(updatedOps.orchestrationDashboard.open, 5)
    assert.equal(updatedOps.orchestrationDashboard.priority, 'coordinate')
    assert.equal(updatedOps.mail.messages, 1)
    assert.equal(updatedOps.mail.drafts, 1)
    assert.equal(updatedOps.presets.count, 1)
    assert.equal(updatedOps.signatures.count, 1)
    assert.equal(updatedOps.apiTokens.active, 1)
    assert.equal(JSON.stringify(updatedOps.apiTokens).includes('tokenHash'), false)
    assert.equal(updatedOps.cloudProviders.active, 1)
    assert.equal(updatedOps.cloudProviders.configured >= 1, true)
    assert.equal(JSON.stringify(updatedOps.cloudProviders).includes('sk-test-roachnet-local-provider-key'), false)
    assert.equal(JSON.stringify(updatedOps.cloudProviders).includes('keyHash'), false)
    assert.equal(updatedOps.userTime.status, 'configured')
    assert.equal(updatedOps.cookbookServeLifecycle.active, 1)
    assert.equal(updatedOps.scopedToolBridge.active, 6)
    assert.equal(updatedOps.tlsOverrides.status, 'configured')
    assert.equal(updatedOps.memoryProvider.count, 2)
    assert.equal(updatedOps.providerOAuth.status, 'needs-user-action')
    assert.equal(updatedOps.embeddingLanes.active, 2)
    assert.equal(updatedOps.embeddingLanes.summaryItems.some((item) => item.includes('768d')), true)
    assert.equal(updatedOps.toolPolicy.status, 'enforced')
    assert.equal(updatedOps.backups.count, 1)
    assert.equal(readFileSync(legacyProviderSecretPath, 'utf8'), legacyProviderSecret)
    const deletedProvider = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/cloud-providers/openai`, { method: 'DELETE' })
    assert.equal(deletedProvider.success, true)
    assert.equal(existsSync(providerSecretPath), false)
    assert.equal(readFileSync(legacyProviderSecretPath, 'utf8'), legacyProviderSecret)
    const fallbackOpenAI = deletedProvider.state.providers.find((provider) => provider.id === 'openai')
    assert.equal(fallbackOpenAI.configured, true)
    assert.equal(fallbackOpenAI.configuredVia, 'legacy-local-secret-file')
    assert.equal(fallbackOpenAI.tokenPrefix, null)
    const redirectedSecretDirectory = path.join(tempRoot, 'outside-provider-secrets')
    const redirectedSecret = 'outside-secret-must-not-be-read'
    mkdirSync(redirectedSecretDirectory, { recursive: true })
    writeFileSync(path.join(redirectedSecretDirectory, 'openai.key'), redirectedSecret)
    rmSync(path.dirname(legacyProviderSecretPath), { recursive: true, force: true })
    symlinkSync(redirectedSecretDirectory, path.dirname(legacyProviderSecretPath), 'dir')
    const symlinkedLegacyState = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/cloud-providers`)
    const symlinkedOpenAI = symlinkedLegacyState.providers.find((provider) => provider.id === 'openai')
    assert.notEqual(symlinkedOpenAI.configuredVia, 'legacy-local-secret-file')
    assert.equal(symlinkedOpenAI.tokenPrefix, null)
    assert.equal(JSON.stringify(symlinkedLegacyState).includes(redirectedSecret), false)
    const redirectedVaultDirectory = path.join(tempRoot, 'outside-vault')
    const ancestorSecret = 'ancestor-secret-must-not-be-read'
    mkdirSync(path.join(redirectedVaultDirectory, 'roachclaw', 'provider-secrets'), { recursive: true })
    writeFileSync(path.join(redirectedVaultDirectory, 'roachclaw', 'provider-secrets', 'openai.key'), ancestorSecret)
    rmSync(path.join(storagePath, 'vault'), { recursive: true, force: true })
    symlinkSync(redirectedVaultDirectory, path.join(storagePath, 'vault'), 'dir')
    const symlinkedAncestorState = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/cloud-providers`)
    const symlinkedAncestorOpenAI = symlinkedAncestorState.providers.find((provider) => provider.id === 'openai')
    assert.notEqual(symlinkedAncestorOpenAI.configuredVia, 'legacy-local-secret-file')
    assert.equal(symlinkedAncestorOpenAI.tokenPrefix, null)
    assert.equal(JSON.stringify(symlinkedAncestorState).includes(ancestorSecret), false)
    const deleteContact = await requestJson(`http://127.0.0.1:${port}/api/roachclaw/contacts/${encodeURIComponent(contacts.contacts[0].id)}`, {
      method: 'DELETE',
    })
    assert.equal(deleteContact.deleted, true)
    assert.equal(deleteContact.state.contacts.length, 0)
    assert.equal(companionRuntime.roachTail.enabled, true)
  } finally {
    await stopNativeApi(child, env)
    assert.equal(child.exitCode === 0 || child.signalCode === 'SIGTERM', true)
    assert.equal(existsSync(statePath), false)
    assert.equal(existsSync(processInfoPath), false)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => releaseServer.close(resolve))
  }
})

test('native RoachTail control plane supports join-key pairing and peer tokens', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-roachtail-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const companionPort = await resolveAvailablePort()
  const companionToken = 'native-api-roachtail-primary-token'
  const processInfoPath = path.join(storagePath, 'logs', 'roachnet-runtime-processes.json')
  const legacyRoachTailPath = path.join(storagePath, 'vault', 'roachtail', 'state.json')
  mkdirSync(path.dirname(legacyRoachTailPath), { recursive: true })
  writeFileSync(legacyRoachTailPath, JSON.stringify({ deviceName: 'Legacy RoachTail Device' }))
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_COMPANION_ENABLED: '1',
    ROACHNET_COMPANION_HOST: '127.0.0.1',
    ROACHNET_COMPANION_PORT: String(companionPort),
    ROACHNET_COMPANION_TOKEN: companionToken,
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    await waitForPath(processInfoPath, child)
    const processInfo = JSON.parse(readFileSync(processInfoPath, 'utf8'))

    const initial = await requestJson(`http://127.0.0.1:${port}/api/companion/roachtail`)
    assert.equal(initial.enabled, true)
    assert.equal(initial.deviceName, 'Legacy RoachTail Device')
    assert.equal(existsSync(path.join(runtimeStateRoot, 'roachtail', 'state.json')), true)
    assert.equal(readFileSync(legacyRoachTailPath, 'utf8'), JSON.stringify({ deviceName: 'Legacy RoachTail Device' }))
    assert.equal(initial.controlPlane.provider, 'roachnet-native')
    assert.equal(initial.controlPlane.designReference, 'headscale')
    assert.equal(initial.preAuthKeys.length, 1)
    assert.equal(initial.preAuthKeys[0].ephemeral, true)
    assert.equal(initial.routes.some((route) => route.id === 'companion-bridge' && route.approved), true)
    assert.match(initial.pairingPayload, /roachnet\.roachtail\.v2/)
    assert.equal(typeof initial.joinCode, 'string')

    const paired = await requestJson(`${processInfo.companionUrl}/api/companion/roachtail/pair`, {
      method: 'POST',
      body: {
        joinCode: initial.joinCode,
        peerName: 'RoachPhone',
        platform: 'ios',
        endpoint: 'roachphone.local',
      },
    })
    assert.equal(paired.success, true)
    assert.match(paired.peerToken, /^rtp_/)
    // Shipped iOS companions (0.1.5) decode `token` and `peerId` as required fields.
    assert.equal(paired.token, paired.peerToken)
    assert.equal(typeof paired.peerId, 'string')
    assert.equal(paired.peerId, paired.state.peers[0].id)
    assert.equal(paired.state.peers.length, 1)
    assert.equal(paired.state.peers[0].name, 'RoachPhone')
    assert.equal(JSON.stringify(paired).includes('tokenHash'), false)

    const peerView = await requestJson(`${processInfo.companionUrl}/api/companion/roachtail`, {
      token: paired.peerToken,
    })
    assert.equal(peerView.joinCode, null)
    assert.equal(peerView.peers.length, 1)
    assert.equal(peerView.peers[0].status, 'connected')

    const refreshed = await requestJson(`http://127.0.0.1:${port}/api/companion/roachtail/affect`, {
      method: 'POST',
      body: { action: 'refresh-join-code' },
    })
    assert.equal(refreshed.success, true)
    assert.notEqual(refreshed.state.joinCode, initial.joinCode)

    const stateFile = JSON.parse(readFileSync(path.join(runtimeStateRoot, 'roachtail', 'state.json'), 'utf8'))
    assert.equal(typeof stateFile.peers[0].tokenHash, 'string')
    assert.equal(stateFile.peers[0].tokenHash.length, 64)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('companion App Store installs route descriptor downloads into the native app', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-appstore-install-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const publicRoot = path.join(tempRoot, 'public')
  const artifactRoot = path.join(publicRoot, 'artifacts')
  const descriptorRoot = path.join(publicRoot, 'downloads', 'maps', 'pmtiles')
  mkdirSync(artifactRoot, { recursive: true })
  mkdirSync(descriptorRoot, { recursive: true })
  const payloadPath = path.join(artifactRoot, 'test-map.pmtiles')
  writeFileSync(payloadPath, 'roachnet app store map payload\n')
  const downloadPort = await resolveAvailablePort()
  const descriptorPath = path.join(descriptorRoot, 'test-map.json')
  writeFileSync(
    descriptorPath,
    JSON.stringify({
      schema: 'org.roachnet.apps.download-descriptor.v1',
      id: 'test-map',
      filename: 'test-map.pmtiles',
      sha256: sha256FileSync(payloadPath),
      sources: [
        {
          type: 'test-source',
          status: 'published',
          url: `http://127.0.0.1:${downloadPort}/artifacts/test-map.pmtiles`,
        },
      ],
    })
  )
  const staticServer = await startStaticDirectoryServer(downloadPort, publicRoot)
  const port = await resolveAvailablePort()
  const companionPort = await resolveAvailablePort()
  const token = 'native-api-appstore-install-token'
  const processInfoPath = path.join(storagePath, 'logs', 'roachnet-runtime-processes.json')
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_APPS_DOWNLOADS_BASE_URL: `http://127.0.0.1:${downloadPort}/downloads`,
    ROACHNET_COMPANION_ENABLED: '1',
    ROACHNET_COMPANION_HOST: '127.0.0.1',
    ROACHNET_COMPANION_PORT: String(companionPort),
    ROACHNET_COMPANION_TOKEN: token,
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    await waitForPath(processInfoPath, child)
    const processInfo = JSON.parse(readFileSync(processInfoPath, 'utf8'))

    const descriptorUrl = `http://127.0.0.1:${downloadPort}/downloads/maps/pmtiles/test-map.json`
    const queued = await requestJson(`${processInfo.companionUrl}/api/companion/install`, {
      method: 'POST',
      token,
      body: {
        action: 'direct-download',
        id: 'test-map',
        title: 'Test Map',
        url: descriptorUrl,
        filetype: 'map',
      },
    })
    assert.equal(queued.success, true)
    assert.equal(queued.action, 'direct-download')
    assert.equal(queued.queued, 1)

    let jobs = []
    for (let attempt = 0; attempt < 60; attempt += 1) {
      jobs = await requestJson(`http://127.0.0.1:${port}/api/downloads/jobs`)
      if (jobs[0]?.status === 'completed' || jobs[0]?.status === 'failed') {
        break
      }
      await new Promise((resolve) => setTimeout(resolve, 150))
    }

    assert.equal(jobs[0]?.status, 'completed')
    assert.equal(jobs[0]?.descriptorUrl, descriptorUrl)
    assert.equal(jobs[0]?.sha256, sha256FileSync(payloadPath))
    assert.equal(existsSync(path.join(storagePath, 'maps', 'pmtiles', 'test-map.pmtiles')), true)
    assert.equal(existsSync(path.join(storagePath, 'maps', 'pmtiles', 'test-map.pmtiles.part')), false)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => staticServer.close(resolve))
  }
})

test('native API downloads through temporary partial files with an explicit byte ceiling', () => {
  const source = readRepoFile('scripts/run-roachnet-native-api.mjs')

  assert.match(source, /NATIVE_API_MAX_DOWNLOAD_BYTES/)
  assert.match(source, /partialFilepath:\s*`\$\{filepath\}\.part`/)
  assert.match(source, /bytesReceived/)
  assert.match(source, /completedAt/)
  assert.match(source, /createWriteStream\(job\.partialFilepath\)/)
  assert.match(source, /renameSync\(job\.partialFilepath,\s*job\.filepath\)/)
  assert.match(source, /rmSync\(job\.partialFilepath,\s*\{\s*force:\s*true\s*\}\)/)
  assert.match(source, /Download exceeded the configured/)
})

test('native API cancels active download jobs and removes partial files', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-cancel-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const downloadPort = await resolveAvailablePort()
  const slowServer = await startSlowDownloadServer(downloadPort)
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    const queued = await requestJson(`http://127.0.0.1:${port}/api/maps/download-remote`, {
      method: 'POST',
      body: { url: `http://127.0.0.1:${downloadPort}/slow.pmtiles` },
    })
    assert.equal(queued.success, true)

    // Polled rather than slept: with the whole suite running (model loads in
    // other files) a fixed 2 s / 500 ms window was sometimes too short.
    let jobs = []
    for (let attempt = 0; attempt < 100; attempt += 1) {
      jobs = await requestJson(`http://127.0.0.1:${port}/api/downloads/jobs`)
      if (jobs.length > 0 && jobs[0].status === 'downloading') {
        break
      }
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    assert.equal(jobs.length, 1)
    assert.equal(jobs[0].status, 'downloading')
    assert.equal(typeof jobs[0].bytesReceived, 'number')

    const cancelled = await requestJson(`http://127.0.0.1:${port}/api/downloads/jobs/${jobs[0].jobId}`, {
      method: 'DELETE',
    })
    assert.equal(cancelled.cancelled, true)

    const finished = path.join(storagePath, 'maps', 'pmtiles', 'slow.pmtiles')
    const partial = `${finished}.part`
    for (let attempt = 0; attempt < 50 && (existsSync(finished) || existsSync(partial)); attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    assert.equal(existsSync(finished), false)
    assert.equal(existsSync(partial), false)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => slowServer.close(resolve))
  }
})

test('native API installs RoachSpeech packs only from RoachNet download descriptors', macOSDittoTest, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-roachspeech-test-'))
  const packID = 'test-roachvoice-pack'
  const archivePath = await createTestRoachSpeechPackZip(tempRoot, packID)
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const downloadPort = await resolveAvailablePort()
  const packServer = await startStaticFileServer(downloadPort, '/test-roachvoice-pack.zip', archivePath)
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    // A bare archive URL carries no checksum and could be any host: refused,
    // through the owner API and the iPhone's install route alike.
    for (const [route, body] of [
      ['/api/roachspeech/model-packs/download', { url: `http://127.0.0.1:${downloadPort}/test-roachvoice-pack.zip`, packID, kind: 'roachVoice' }],
      ['/api/companion/install', { action: 'roachspeech-pack', url: `http://127.0.0.1:${downloadPort}/test-roachvoice-pack.zip`, pack: packID, kind: 'roachVoice' }],
    ]) {
      const refused = await requestHttp(`http://127.0.0.1:${port}${route}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(body),
        timeoutMs: 5_000,
      })
      assert.equal(refused.status, 400, route)
      assert.match(JSON.parse(await refused.text()).error, /download descriptors/, route)
    }
    const jobs = await requestJson(`http://127.0.0.1:${port}/api/downloads/jobs`)
    assert.equal(jobs.length, 0)
    assert.equal(existsSync(path.join(storagePath, 'RoachSpeech', 'ModelPacks', packID)), false)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => packServer.close(resolve))
  }
})

test('native API resolves Apps download descriptors before installing RoachSpeech packs', macOSDittoTest, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-roachspeech-descriptor-test-'))
  const packID = 'test-roachvoice-descriptor-pack'
  const archivePath = await createTestRoachSpeechPackZip(tempRoot, packID)
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const downloadPort = await resolveAvailablePort()
  const descriptorPort = await resolveAvailablePort()
  const packServer = await startStaticFileServer(downloadPort, '/test-roachvoice-descriptor-pack.zip', archivePath)
  const descriptorPath = path.join(tempRoot, 'descriptor.json')
  writeFileSync(
    descriptorPath,
    JSON.stringify({
      schema: 'org.roachnet.apps.download-descriptor.v1',
      id: packID,
      filename: 'test-roachvoice-descriptor-pack.zip',
      sha256: sha256FileSync(archivePath),
      sources: [
        {
          type: 'test-source',
          url: `http://127.0.0.1:${downloadPort}/test-roachvoice-descriptor-pack.zip`,
        },
      ],
    })
  )
  const descriptorServer = await startStaticFileServer(descriptorPort, '/downloads/model-packs/test-roachvoice-descriptor-pack.json', descriptorPath)
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_APPS_DOWNLOADS_BASE_URL: `http://127.0.0.1:${descriptorPort}/downloads`,
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    const queued = await requestJson(`http://127.0.0.1:${port}/api/roachspeech/model-packs/download`, {
      method: 'POST',
      body: {
        url: `http://127.0.0.1:${descriptorPort}/downloads/model-packs/test-roachvoice-descriptor-pack.json`,
        packID,
        kind: 'roachVoice',
      },
    })
    assert.equal(queued.success, true)
    assert.equal(queued.packID, packID)

    let jobs = []
    for (let attempt = 0; attempt < 60; attempt += 1) {
      jobs = await requestJson(`http://127.0.0.1:${port}/api/downloads/jobs`)
      if (jobs[0]?.status === 'completed' || jobs[0]?.status === 'failed') {
        break
      }
      await new Promise((resolve) => setTimeout(resolve, 150))
    }
    assert.equal(jobs[0]?.status, 'completed')
    assert.equal(jobs[0]?.installStatus, 'installed')
    assert.equal(jobs[0]?.descriptorUrl, `http://127.0.0.1:${descriptorPort}/downloads/model-packs/test-roachvoice-descriptor-pack.json`)
    assert.equal(existsSync(path.join(storagePath, 'RoachSpeech', 'ModelPacks', packID, 'RoachSpeechPack.json')), true)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => packServer.close(resolve))
    await new Promise((resolve) => descriptorServer.close(resolve))
  }
})

// Swift runtime only (`swiftOnly` is declared further down).
test('native API holds catalog RoachSpeech packs to the catalog digest', nativeApiBinary ? {} : { skip: 'Swift runtime behaviour; set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-roachspeech-pin-test-'))
  // A real catalog pack id, served by a descriptor that names a different archive digest.
  const packID = 'roachvoice-kokoro-82m-int8-coreml'
  const descriptorPort = await resolveAvailablePort()
  const descriptorPath = path.join(tempRoot, 'descriptor.json')
  writeFileSync(
    descriptorPath,
    JSON.stringify({
      schema: 'org.roachnet.apps.download-descriptor.v1',
      id: packID,
      filename: `${packID}.zip`,
      sha256: 'ab'.repeat(32),
      sources: [{ type: 'test-source', url: `http://127.0.0.1:${descriptorPort}/elsewhere.zip` }],
    })
  )
  const descriptorServer = await startStaticFileServer(descriptorPort, `/downloads/model-packs/${packID}.json`, descriptorPath)
  const port = await resolveAvailablePort()
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'storage'),
    ROACHNET_RUNTIME_STATE_ROOT: path.join(tempRoot, 'state'),
    ROACHNET_APPS_DOWNLOADS_BASE_URL: `http://127.0.0.1:${descriptorPort}/downloads`,
    ROACHNET_PACK_CATALOG_URL: '',
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), { cwd: repoRoot, env, stdio: ['ignore', 'pipe', 'pipe'] })
  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    const response = await requestHttp(`http://127.0.0.1:${port}/api/roachspeech/model-packs/download`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ url: `http://127.0.0.1:${descriptorPort}/downloads/model-packs/${packID}.json`, packID, kind: 'roachVoice' }),
      timeoutMs: 10_000,
    })
    assert.equal(response.status, 422)
    assert.match(JSON.parse(await response.text()).error, /does not match the catalog/)
    const jobs = await requestJson(`http://127.0.0.1:${port}/api/downloads/jobs`)
    assert.equal(jobs.length, 0)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => descriptorServer.close(resolve))
  }
})

test('native API reassembles chunked Apps descriptors before installing RoachSpeech packs', macOSDittoTest, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-roachspeech-chunked-test-'))
  const packID = 'test-roachvoice-chunked-pack'
  const archivePath = await createTestRoachSpeechPackZip(tempRoot, packID)
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const downloadPort = await resolveAvailablePort()
  const publicRoot = path.join(tempRoot, 'public')
  const partsRoot = path.join(publicRoot, 'parts')
  mkdirSync(partsRoot, { recursive: true })
  const parts = splitFileIntoParts(
    archivePath,
    partsRoot,
    `http://127.0.0.1:${downloadPort}/parts`,
    512
  )
  const descriptorPath = path.join(publicRoot, 'downloads', 'model-packs', 'test-roachvoice-chunked-pack.json')
  mkdirSync(path.dirname(descriptorPath), { recursive: true })
  writeFileSync(
    descriptorPath,
    JSON.stringify({
      schema: 'org.roachnet.apps.download-descriptor.v1',
      id: packID,
      filename: 'test-roachvoice-chunked-pack.zip',
      bytes: readFileSync(archivePath).byteLength,
      sha256: sha256FileSync(archivePath),
      parts,
      sources: [
        {
          type: 'internet-archive-parts',
          status: 'published-after-upload',
          partCount: parts.length,
        },
      ],
    })
  )
  const staticServer = await startStaticDirectoryServer(downloadPort, publicRoot)
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_APPS_DOWNLOADS_BASE_URL: `http://127.0.0.1:${downloadPort}/downloads`,
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    const queued = await requestJson(`http://127.0.0.1:${port}/api/roachspeech/model-packs/download`, {
      method: 'POST',
      body: {
        url: `http://127.0.0.1:${downloadPort}/downloads/model-packs/test-roachvoice-chunked-pack.json`,
        packID,
        kind: 'roachVoice',
      },
    })
    assert.equal(queued.success, true)
    assert.equal(queued.packID, packID)

    let jobs = []
    for (let attempt = 0; attempt < 60; attempt += 1) {
      jobs = await requestJson(`http://127.0.0.1:${port}/api/downloads/jobs`)
      if (jobs[0]?.status === 'completed' || jobs[0]?.status === 'failed') {
        break
      }
      await new Promise((resolve) => setTimeout(resolve, 150))
    }
    assert.equal(jobs[0]?.status, 'completed')
    assert.equal(jobs[0]?.installStatus, 'installed')
    assert.equal(jobs[0]?.sha256, sha256FileSync(archivePath))
    assert.equal(existsSync(path.join(storagePath, 'RoachSpeech', 'ModelPacks', packID, 'RoachSpeechPack.json')), true)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => staticServer.close(resolve))
  }
})

test('native API rejects oversized JSON bodies with a public 413 response', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-body-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_NATIVE_API_MAX_BODY_BYTES: '64',
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    const response = await requestHttp(`http://127.0.0.1:${port}/api/benchmark/run`, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ payload: 'x'.repeat(128) }),
      timeoutMs: 5_000,
    })
    assert.equal(response.status, 413)
    assert.match((await response.json()).error, /larger than 64 bytes/)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('native API removes partial update downloads after transfer failure', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-update-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const releasesPort = await resolveAvailablePort()
  const releaseServer = await startBrokenReleaseServer(releasesPort)
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_GITHUB_RELEASES_API_URL: `http://127.0.0.1:${releasesPort}/releases`,
    ROACHNET_RELEASES_URL: `http://127.0.0.1:${releasesPort}/release`,
    ROACHNET_OPEN_UPDATES: '0',
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    const update = await requestJson(`http://127.0.0.1:${port}/api/system/update`, { method: 'POST' })
    assert.equal(update.success, true)

    let updateStatus = null
    for (let attempt = 0; attempt < 80; attempt += 1) {
      updateStatus = await requestJson(`http://127.0.0.1:${port}/api/system/update/status`)
      if (updateStatus.stage === 'error') {
        break
      }
      await new Promise((resolve) => setTimeout(resolve, 250))
    }

    assert.equal(updateStatus.stage, 'error')
    assert.match(updateStatus.message, /Download from/)
    assert.equal(existsSync(path.join(storagePath, 'updates', 'broken.dmg')), false)
    assert.equal(existsSync(path.join(storagePath, 'updates', 'broken.dmg.part')), false)
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => releaseServer.close(resolve))
  }
})

async function runUpdateLane(releaseOptions, assertion) {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-update-verify-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const releasesPort = await resolveAvailablePort()
  const releaseServer = await startBrokenReleaseServer(releasesPort, releaseOptions)
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_GITHUB_RELEASES_API_URL: `http://127.0.0.1:${releasesPort}/releases`,
    ROACHNET_RELEASES_URL: `http://127.0.0.1:${releasesPort}/release`,
    ROACHNET_OPEN_UPDATES: '0',
    HOST: '127.0.0.1',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), { cwd: repoRoot, env, stdio: ['ignore', 'pipe', 'pipe'] })
  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    const update = await requestHttp(`http://127.0.0.1:${port}/api/system/update`, {
      method: 'POST',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: '{}',
      timeoutMs: 10_000,
    })
    const updatePayload = JSON.parse(await response_text(update))
    let updateStatus = null
    for (let attempt = 0; attempt < 80; attempt += 1) {
      updateStatus = await requestJson(`http://127.0.0.1:${port}/api/system/update/status`)
      if (['error', 'ready', 'idle'].includes(updateStatus.stage)) break
      await new Promise((resolve) => setTimeout(resolve, 250))
    }
    await assertion({ updatePayload, updateStatus, storagePath })
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
    await new Promise((resolve) => releaseServer.close(resolve))
  }
}

async function response_text(response) {
  return await response.text()
}

// The 1.0.6 hardening (checksum sidecars, strict framing, Host checks,
// single-use join codes) lives in the Swift runtime. The dependency-free Node
// reference API is a compatibility lane and does not implement it, so these
// run only against a built roachnet-runtime.
const swiftOnly = nativeApiBinary ? {} : { skip: 'Swift runtime behaviour; set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

test('native API refuses to queue an installer whose release has no checksum sidecar', swiftOnly, async () => {
  await runUpdateLane({ mode: 'good', sidecar: false }, async ({ updatePayload, updateStatus, storagePath }) => {
    assert.equal(updatePayload.success, false)
    assert.match(updatePayload.error, /no verifiable checksum/)
    assert.equal(updateStatus.stage, 'error')
    assert.equal(existsSync(path.join(storagePath, 'updates', 'broken.dmg')), false)
  })
})

test('native API discards an installer whose bytes do not match the published checksum', swiftOnly, async () => {
  await runUpdateLane({ mode: 'tampered' }, async ({ updatePayload, updateStatus, storagePath }) => {
    assert.equal(updatePayload.success, true)
    assert.equal(updateStatus.stage, 'error')
    assert.match(updateStatus.message, /Checksum mismatch/)
    assert.equal(existsSync(path.join(storagePath, 'updates', 'broken.dmg')), false)
  })
})

test('native API keeps an installer whose bytes match the published checksum', async () => {
  await runUpdateLane({ mode: 'good' }, async ({ updatePayload, updateStatus, storagePath }) => {
    assert.equal(updatePayload.success, true)
    assert.equal(updateStatus.stage, 'ready')
    const installer = path.join(storagePath, 'updates', 'broken.dmg')
    assert.equal(existsSync(installer), true)
    assert.equal(createHash('sha256').update(readFileSync(installer)).digest('hex'), fakeInstallerSha256)
  })
})

async function withNativeApi(extraEnv, body) {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-hardening-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const port = await resolveAvailablePort()
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    HOST: '127.0.0.1',
    PORT: String(port),
    ...extraEnv,
  }
  const child = spawn(...nativeApiCommand(), { cwd: repoRoot, env, stdio: ['ignore', 'pipe', 'pipe'] })
  try {
    await waitForHealth(`http://127.0.0.1:${port}/api/health`, child)
    await body({ port, storagePath, child })
  } finally {
    await stopNativeApi(child, env)
    await rm(tempRoot, { recursive: true, force: true })
  }
}

// Sends raw bytes to the listener and returns the status line, so malformed
// framing can be exercised without a client library repairing it first.
function rawRequest(port, text) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1')
    let received = ''
    socket.setTimeout(5_000, () => { socket.destroy(); reject(new Error('raw request timed out')) })
    socket.on('connect', () => socket.write(text))
    socket.on('data', (chunk) => { received += chunk.toString('utf8') })
    socket.on('error', reject)
    socket.on('close', () => resolve(received))
  })
}

test('native API survives malformed body framing and stays up', swiftOnly, async () => {
  await withNativeApi({}, async ({ port }) => {
    const negative = await rawRequest(port, 'POST /api/benchmark/run HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: -1\r\n\r\n')
    assert.match(negative, /^HTTP\/1\.1 400/)
    const overflow = await rawRequest(
      port,
      'POST /api/benchmark/run HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n7fffffffffffffff\r\n'
    )
    assert.match(overflow, /^HTTP\/1\.1 413/)
    const health = await requestJson(`http://127.0.0.1:${port}/api/health`)
    assert.equal(health.status, 'ok')
  })
})

test('native API rejects non-loopback Host headers and non-JSON bodies', swiftOnly, async () => {
  await withNativeApi({}, async ({ port }) => {
    const rebound = await requestHttp(`http://127.0.0.1:${port}/api/health`, {
      headers: { Host: 'attacker.example', Accept: 'application/json' },
      timeoutMs: 5_000,
    })
    assert.equal(rebound.status, 403)
    const bracketed = await requestHttp(`http://127.0.0.1:${port}/api/health`, {
      headers: { Host: `[::1]:${port}`, Accept: 'application/json' },
      timeoutMs: 5_000,
    })
    assert.equal(bracketed.status, 200)
    const formPost = await requestHttp(`http://127.0.0.1:${port}/api/companion/install`, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain', Accept: 'application/json' },
      body: '{"action":"base-map-assets"}',
      timeoutMs: 5_000,
    })
    assert.equal(formPost.status, 415)
    const jsonPost = await requestHttp(`http://127.0.0.1:${port}/api/companion/install`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8', Accept: 'application/json' },
      body: '{"action":"base-map-assets"}',
      timeoutMs: 5_000,
    })
    assert.equal(jsonPost.status, 200)
  })
})

test('the JavaScript compatibility runtime says plainly that it cannot install feature packs', nativeApiBinary ? { skip: 'JavaScript lane only.' } : {}, async () => {
  await withNativeApi({}, async ({ port }) => {
    const response = await requestHttp(`http://127.0.0.1:${port}/api/companion/install`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ action: 'pack', pack: 'roachnet-retro-terminals' }),
      timeoutMs: 5_000,
    })
    assert.equal(response.status, 400)
    assert.match(JSON.parse(await response.text()).error, /native runtime/)
  })
})

test('native companion install accepts catalog packs by id and nothing else', swiftOnly, async () => {
  await withNativeApi({ ROACHNET_PACK_CATALOG_URL: '' }, async ({ port }) => {
    const post = async (body) => {
      const response = await requestHttp(`http://127.0.0.1:${port}/api/companion/install`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify(body),
        timeoutMs: 5_000,
      })
      return { status: response.status, payload: JSON.parse(await response.text()) }
    }
    const missing = await post({ action: 'pack' })
    assert.equal(missing.status, 400)
    assert.match(missing.payload.error, /Pack id is missing/)
    // The id is looked up in the runtime's own catalog; a URL in the body is ignored.
    const unknown = await post({ action: 'pack', pack: 'no-such-pack', url: 'https://example.com/evil.json' })
    assert.equal(unknown.status, 404)
    assert.match(unknown.payload.error, /no pack named no-such-pack/)
  })
})

test('native RoachTail join codes pair exactly once and retire after repeated wrong guesses', swiftOnly, async () => {
  const companionPort = await resolveAvailablePort()
  await withNativeApi(
    {
      ROACHNET_COMPANION_ENABLED: '1',
      ROACHNET_COMPANION_HOST: '127.0.0.1',
      ROACHNET_COMPANION_PORT: String(companionPort),
      ROACHNET_COMPANION_TOKEN: 'native-api-join-once-token',
    },
    async ({ port, storagePath, child }) => {
      await waitForPath(path.join(storagePath, 'logs', 'roachnet-runtime-processes.json'), child)
      const initial = await requestJson(`http://127.0.0.1:${port}/api/companion/roachtail`)
      const pairUrl = `http://127.0.0.1:${companionPort}/api/companion/roachtail/pair`
      const first = await requestJson(pairUrl, { method: 'POST', body: { joinCode: initial.joinCode, peerName: 'Phone A', peerId: 'rtpeer_chosen_by_client' } })
      assert.equal(first.success, true)
      assert.notEqual(first.peerId, 'rtpeer_chosen_by_client')
      const second = await requestHttp(pairUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ joinCode: initial.joinCode, peerName: 'Phone B' }),
        timeoutMs: 5_000,
      })
      assert.equal(second.status, 401)
      const refreshed = await requestJson(`http://127.0.0.1:${port}/api/companion/roachtail`)
      assert.notEqual(refreshed.joinCode, initial.joinCode)
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const wrong = await requestHttp(pairUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
          body: JSON.stringify({ joinCode: 'WRONG-GUESS', peerName: 'Phone C' }),
          timeoutMs: 5_000,
        })
        assert.equal(wrong.status, 401)
      }
      const retired = await requestJson(`http://127.0.0.1:${port}/api/companion/roachtail`)
      assert.notEqual(retired.joinCode, refreshed.joinCode)
      const peers = await requestJson(`http://127.0.0.1:${port}/api/companion/roachtail`)
      assert.equal(peers.peers.length, 1)
    }
  )
})

// Feature packs live in the Swift runtime only; the dependency-free Node reference API does not implement them.
const packsNeedBinary = nativeApiBinary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

test('native API manages feature packs: catalog, offline install, toggles and data-preserving uninstall', packsNeedBinary, async () => {
  await withNativeApi({}, async ({ port, storagePath }) => {
    const catalog = await requestJson(`http://127.0.0.1:${port}/api/packs`)
    assert.equal(catalog.schema, 'org.roachnet.packs.v1')
    const org = catalog.packs.find((pack) => pack.id === 'org')
    assert.equal(org.bundled, true)
    assert.equal(org.enabled, true)
    assert.deepEqual(org.dependencies.map((dependency) => dependency.id), ['roachclaw'])

    // The published catalog (collections/packs.json) is listed as available: the
    // speech packs are not installed on a fresh storage root and are never
    // enabled on their own.
    const narrator = catalog.packs.find((pack) => pack.id === 'roachvoice-kokoro-82m-int8-coreml')
    assert.equal(narrator.kind, 'resource')
    assert.equal(narrator.installed, false)
    assert.equal(narrator.available, true)
    assert.equal(narrator.enabled, false)
    assert.equal(narrator.handler, 'roachspeech-pack')
    assert.equal(narrator.downloadBytes, 80330676)
    assert.equal(narrator.installedBytes, null, 'sizes are not walked unless asked')
    const sized = await requestJson(`http://127.0.0.1:${port}/api/packs?sizes=1`)
    assert.equal(sized.sizesIncluded, true)
    assert.equal(typeof sized.packs.find((pack) => pack.id === 'org').installedBytes, 'number')
    const unknown = await requestHttp(`http://127.0.0.1:${port}/api/packs/install`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, body: JSON.stringify({ id: 'no-such-pack' }), timeoutMs: 5_000,
    })
    assert.equal(unknown.status, 404)
    const notInstalled = await requestHttp(`http://127.0.0.1:${port}/api/packs/roachvoice-kokoro-82m-int8-coreml/enable`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, body: '{}', timeoutMs: 5_000,
    })
    assert.equal(notInstalled.status, 404, 'an available pack cannot be enabled before it is installed')

    // A capability pack with enabled dependents cannot be switched off first.
    const refused = await requestHttp(`http://127.0.0.1:${port}/api/packs/roachclaw/disable`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, body: '{}', timeoutMs: 5_000,
    })
    assert.equal(refused.status, 409)

    // Offline install from a local package with a verified digest.
    const payload = Buffer.from('a tiny voice model')
    const packageRoot = path.join(storagePath, '..', 'voice-pack')
    mkdirSync(path.join(packageRoot, 'model'), { recursive: true })
    writeFileSync(path.join(packageRoot, 'model', 'weights.bin'), payload)
    writeFileSync(path.join(packageRoot, 'manifest.json'), JSON.stringify({
      schema: 'org.roachnet.pack.v1', id: 'voice-contract-test', version: '1.0.0', kind: 'resource', name: 'Contract voice',
      requires: { roachnet: '1.0.0' },
      resources: [{ path: 'model/weights.bin', sha256: createHash('sha256').update(payload).digest('hex'), bytes: payload.length }],
      dataRoots: [{ path: 'RoachSpeech/voices/contract', description: 'Recordings' }],
    }))
    const installed = await requestJson(`http://127.0.0.1:${port}/api/packs/install`, { method: 'POST', body: { packagePath: packageRoot } })
    assert.equal(installed.status, 'installed')
    assert.equal(installed.pack.enabled, true)
    assert.equal(existsSync(path.join(storagePath, 'packs', 'installed', 'voice-contract-test', '1.0.0', 'model', 'weights.bin')), true)
    assert.equal(existsSync(path.join(storagePath, 'packs', 'installed', 'voice-contract-test', '1.0.0', 'receipt.json')), true)

    // Tampered package is refused and leaves nothing behind.
    writeFileSync(path.join(packageRoot, 'model', 'weights.bin'), Buffer.from('tampered bytes here'))
    const tampered = await requestHttp(`http://127.0.0.1:${port}/api/packs/install`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, body: JSON.stringify({ packagePath: packageRoot }), timeoutMs: 5_000,
    })
    assert.equal(tampered.status, 422)
    assert.equal(readFileSync(path.join(storagePath, 'packs', 'installed', 'voice-contract-test', '1.0.0', 'model', 'weights.bin')).equals(payload), true)

    const dataRoot = path.join(storagePath, 'RoachSpeech', 'voices', 'contract')
    mkdirSync(dataRoot, { recursive: true })
    writeFileSync(path.join(dataRoot, 'take-1.wav'), 'recording')
    const removed = await requestJson(`http://127.0.0.1:${port}/api/packs/voice-contract-test/uninstall`, { method: 'POST', body: {} })
    assert.deepEqual(removed.retainedDataRoots, [dataRoot])
    assert.equal(existsSync(path.join(dataRoot, 'take-1.wav')), true, 'uninstall keeps user data by default')
    assert.equal(existsSync(path.join(storagePath, 'packs', 'installed', 'voice-contract-test')), false)
    const after = await requestJson(`http://127.0.0.1:${port}/api/packs`)
    assert.equal(after.packs.some((pack) => pack.id === 'voice-contract-test'), false)
  })
})

test('native API refuses non-loopback bind hosts before listening', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-native-api-host-test-'))
  const storagePath = path.join(tempRoot, 'storage')
  const runtimeStateRoot = path.join(tempRoot, 'state')
  const logPath = path.join(storagePath, 'logs', 'roachnet-native-api.log')
  const port = await resolveAvailablePort()
  const env = {
    ...process.env,
    ROACHNET_STORAGE_PATH: storagePath,
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    HOST: '192.0.2.10',
    PORT: String(port),
  }
  const child = spawn(...nativeApiCommand(), {
    cwd: repoRoot,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  try {
    const exitCode = await new Promise((resolve) => child.once('exit', (code) => resolve(code)))
    assert.equal(exitCode, 1)
    assert.match(readFileSync(logPath, 'utf8'), /only binds to loopback hosts/)
  } finally {
    await rm(tempRoot, { recursive: true, force: true })
  }
})
