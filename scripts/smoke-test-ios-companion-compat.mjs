#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { randomBytes } from 'node:crypto'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const iosRepoRoot = process.env.ROACHNET_IOS_REPO
  ? path.resolve(process.env.ROACHNET_IOS_REPO)
  : path.resolve(repoRoot, '..', 'RoachNet-iOS')
const keepTempArtifacts = process.env.ROACHNET_SMOKE_KEEP_TEMP === '1'
const pollIntervalMs = 1_500
const startupTimeoutMs = 300_000

function assert(condition, message) {
  if (!condition) {
    throw new Error(message)
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function resolveAvailablePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      if (typeof address !== 'object' || !address) {
        reject(new Error('Failed to allocate a local smoke port.'))
        return
      }

      const port = address.port
      server.close((error) => {
        if (error) {
          reject(error)
          return
        }

        resolve(port)
      })
    })
  })
}

function spawnProcess(command, args, options = {}) {
  const child = spawn(command, args, {
    cwd: options.cwd || repoRoot,
    env: options.env || process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  let stdout = ''
  let stderr = ''

  child.stdout?.on('data', (chunk) => {
    stdout += chunk.toString()
  })
  child.stderr?.on('data', (chunk) => {
    stderr += chunk.toString()
  })

  return {
    child,
    getLogs() {
      return {
        stdout: stdout.trim(),
        stderr: stderr.trim(),
      }
    },
  }
}

function formatLogs(label, logs) {
  const sections = []

  if (logs?.stdout?.trim()) {
    sections.push(`${label} stdout:\n${logs.stdout.trim()}`)
  }

  if (logs?.stderr?.trim()) {
    sections.push(`${label} stderr:\n${logs.stderr.trim()}`)
  }

  return sections.join('\n\n')
}

async function stopChild(child, signal = 'SIGTERM') {
  if (!child || child.killed || child.exitCode !== null) {
    return
  }

  child.kill(signal)
  await new Promise((resolve) => {
    const timeout = setTimeout(() => {
      if (child.exitCode === null) {
        child.kill('SIGKILL')
      }
      resolve()
    }, 8_000)

    child.once('exit', () => {
      clearTimeout(timeout)
      resolve()
    })
  })
}

async function waitForHttpOk(url, timeoutMs) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    try {
      const response = await fetch(url, {
        headers: { Accept: 'application/json' },
      })

      if (response.ok) {
        return
      }
    } catch {
      // still booting
    }

    await sleep(pollIntervalMs)
  }

  throw new Error(`Timed out waiting for ${url}`)
}

async function waitForAuthorizedJson(url, token, timeoutMs) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    try {
      return await fetchJson(url, token)
    } catch {
      // still booting or companion bridge not ready yet
    }

    await sleep(pollIntervalMs)
  }

  throw new Error(`Timed out waiting for authorized companion payload at ${url}`)
}

async function waitForPath(targetPath, timeoutMs, label = targetPath) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    if (existsSync(targetPath)) {
      return
    }

    await sleep(250)
  }

  throw new Error(`Timed out waiting for ${label}`)
}

async function fetchJson(url, token, options = {}) {
  const headers = {
    Accept: 'application/json',
    Authorization: `Bearer ${token}`,
    ...(options.body ? { 'Content-Type': 'application/json' } : {}),
    ...(options.headers || {}),
  }

  const response = await fetch(url, {
    method: options.method || 'GET',
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined,
  })

  const text = await response.text()
  let payload = null

  try {
    payload = text ? JSON.parse(text) : null
  } catch {
    payload = text
  }

  if (!response.ok) {
    throw new Error(`Request to ${url} failed with ${response.status}: ${typeof payload === 'string' ? payload : JSON.stringify(payload)}`)
  }

  return payload
}

function buildRuntimeEnv({ homePath, storagePath, runtimePort, companionPort, companionToken }) {
  const localBinRoot = path.join(homePath, 'RoachNet', 'bin')

  return {
    ...process.env,
    HOME: homePath,
    USERPROFILE: homePath,
    LOGNAME: 'roachnet-companion-smoke',
    USER: 'roachnet-companion-smoke',
    TMPDIR: path.join(homePath, 'tmp'),
    HOST: '127.0.0.1',
    PORT: String(runtimePort),
    NOMAD_STORAGE_PATH: storagePath,
    OPENCLAW_WORKSPACE_PATH: path.join(storagePath, 'openclaw'),
    OLLAMA_MODELS: path.join(storagePath, 'ollama'),
    OLLAMA_BASE_URL: 'http://127.0.0.1:36434',
    OPENCLAW_BASE_URL: 'http://127.0.0.1:13001',
    ROACHNET_RUNTIME_STATE_ROOT: path.join(storagePath, 'state', 'runtime-state'),
    ROACHNET_LOCAL_BIN_PATH: localBinRoot,
    ROACHNET_NO_BROWSER: '1',
    ROACHNET_DISABLE_QUEUE: '1',
    ROACHNET_CONTAINERLESS_MODE: '1',
    ROACHNET_INSTALL_PROFILE: 'smoke-ios-companion',
    ROACHNET_BOOTSTRAP_PENDING: '0',
    ROACHNET_COMPANION_ENABLED: '1',
    ROACHNET_COMPANION_HOST: '127.0.0.1',
    ROACHNET_COMPANION_PORT: String(companionPort),
    ROACHNET_COMPANION_TOKEN: companionToken,
    ROACHNET_COMPANION_ADVERTISED_URL: `http://127.0.0.1:${companionPort}`,
    ROACHTAIL_ENABLED: '1',
    ROACHNET_TRACE_REQUESTS: '0',
  }
}

function writeFixture(directory, filename, payload) {
  const targetPath = path.join(directory, filename)
  writeFileSync(targetPath, `${JSON.stringify(payload, null, 2)}\n`)
  return targetPath
}

function parseServerBaseUrl(adminLogPath, launcherLogs = '') {
  const launcherMatch = launcherLogs.match(/Web UI:\s+(https?:\/\/[^\s/]+(?::\d+)?)\/home/)
  if (launcherMatch?.[1]) {
    return launcherMatch[1]
  }

  const content = existsSync(adminLogPath) ? readFileSync(adminLogPath, 'utf8') : ''
  const matches = [...content.matchAll(/started HTTP server on (https?:\/\/[^\s"]+)/g)]
  return matches.at(-1)?.[1] || null
}

function readCompanionBaseUrl(processInfoPath) {
  const content = JSON.parse(readFileSync(processInfoPath, 'utf8'))
  return content?.companionUrl || null
}

async function runCommand(command, args, options = {}) {
  const handle = spawnProcess(command, args, options)
  const exitCode = await new Promise((resolve) => {
    handle.child.once('exit', (code) => resolve(code ?? 0))
  })

  if (exitCode !== 0) {
    throw new Error(formatLogs(`${path.basename(command)} ${args.join(' ')}`, handle.getLogs()) || `${command} ${args.join(' ')} failed with exit code ${exitCode}`)
  }
}

async function verifyIOSFixtures(fixturesDir) {
  if (!existsSync(iosRepoRoot)) {
    console.warn(`Skipping iOS compatibility smoke because ${iosRepoRoot} does not exist.`)
    return
  }

  const projectPath = path.join(iosRepoRoot, 'RoachNetCompanion.xcodeproj')
  const modelPath = path.join(iosRepoRoot, 'RoachNetCompanion', 'Core', 'CompanionModels.swift')
  const derivedDataPath = path.join(fixturesDir, 'DerivedData')
  const checkerPath = path.join(fixturesDir, 'companion-fixture-check')
  const checkerSourcePath = path.join(fixturesDir, 'companion-fixture-check.swift')

  assert(existsSync(projectPath), `Missing iOS project at ${projectPath}`)
  assert(existsSync(modelPath), `Missing iOS companion model file at ${modelPath}`)

  writeFileSync(
    checkerSourcePath,
    `
import Foundation

@main
struct CompanionFixtureCheck {
    static func decode<T: Decodable>(_ type: T.Type, from path: String, decoder: JSONDecoder) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try decoder.decode(type, from: data)
    }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 5 else {
            throw NSError(domain: "RoachNetSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 5 fixture paths."])
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        try decode(CompanionBootstrapResponse.self, from: args[0], decoder: decoder)
        try decode(CompanionRuntimeSummary.self, from: args[1], decoder: decoder)
        try decode(CompanionRoachTailStatus.self, from: args[2], decoder: decoder)
        try decode(CompanionRoachSyncStatus.self, from: args[3], decoder: decoder)
        try decode(CompanionVaultSummary.self, from: args[4], decoder: decoder)
        print("Decoded companion fixtures against iOS models.")
    }
}
`.trimStart()
  )

  await runCommand('ruby', [path.join(iosRepoRoot, 'scripts', 'generate_xcodeproj.rb')], { cwd: iosRepoRoot })
  await runCommand(
    'xcodebuild',
    [
      '-project',
      projectPath,
      '-scheme',
      'RoachNetCompanion',
      '-configuration',
      'Debug',
      '-sdk',
      'iphonesimulator',
      '-destination',
      'generic/platform=iOS Simulator',
      'CODE_SIGNING_ALLOWED=NO',
      'CODE_SIGNING_REQUIRED=NO',
      'CODE_SIGN_IDENTITY=',
      '-derivedDataPath',
      derivedDataPath,
      'build',
    ],
    {
      cwd: iosRepoRoot,
      env: {
        ...process.env,
        DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer',
      },
    }
  )

  await runCommand(
    'swiftc',
    [
      '-parse-as-library',
      modelPath,
      checkerSourcePath,
      '-o',
      checkerPath,
    ],
    { cwd: iosRepoRoot }
  )

  await runCommand(
    checkerPath,
    [
      path.join(fixturesDir, 'bootstrap.json'),
      path.join(fixturesDir, 'runtime.json'),
      path.join(fixturesDir, 'roachtail.json'),
      path.join(fixturesDir, 'roachsync.json'),
      path.join(fixturesDir, 'vault.json'),
    ],
    { cwd: iosRepoRoot }
  )
}

async function main() {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-ios-companion-smoke-'))
  const homePath = path.join(tempRoot, 'home')
  const storagePath = path.join(homePath, 'RoachNet', 'storage')
  const tmpPath = path.join(homePath, 'tmp')

  mkdirSync(storagePath, { recursive: true })
  mkdirSync(tmpPath, { recursive: true })

  const companionPort = await resolveAvailablePort()
  const companionToken = randomBytes(24).toString('hex')
  const runtimeEnv = buildRuntimeEnv({
    homePath,
    storagePath,
    runtimePort: await resolveAvailablePort(),
    companionPort,
    companionToken,
  })

  const runtimeHandle = spawnProcess(process.execPath, [path.join(repoRoot, 'scripts', 'run-roachnet.mjs')], {
    cwd: repoRoot,
    env: runtimeEnv,
  })

  const logsRoot = path.join(storagePath, 'logs')
  const adminLogPath = path.join(logsRoot, 'admin.log')
  const processInfoPath = path.join(logsRoot, 'roachnet-runtime-processes.json')

  try {
    console.log('Waiting for contained desktop runtime health...')
    await waitForPath(adminLogPath, startupTimeoutMs, 'runtime admin log')
    await waitForPath(processInfoPath, startupTimeoutMs, 'runtime process info')

    const runtimeBaseUrl = parseServerBaseUrl(adminLogPath, runtimeHandle.getLogs().stdout)
    const companionBaseUrl = readCompanionBaseUrl(processInfoPath)
    assert(runtimeBaseUrl, 'Unable to resolve the contained desktop runtime URL from admin.log.')
    assert(companionBaseUrl, 'Unable to resolve the contained companion URL from runtime process info.')

    await waitForHttpOk(`${runtimeBaseUrl}/api/health`, startupTimeoutMs)
    console.log('Waiting for companion bridge payload...')
    await waitForAuthorizedJson(`${companionBaseUrl}/api/companion/bootstrap`, companionToken, startupTimeoutMs)

    console.log('Collecting companion fixtures...')
    const bootstrap = await fetchJson(`${companionBaseUrl}/api/companion/bootstrap`, companionToken)
    const runtime = await fetchJson(`${companionBaseUrl}/api/companion/runtime`, companionToken)
    const roachtail = await fetchJson(`${companionBaseUrl}/api/companion/roachtail`, companionToken)
    const roachsync = await fetchJson(`${companionBaseUrl}/api/companion/roachsync`, companionToken)
    const vault = await fetchJson(`${companionBaseUrl}/api/companion/vault`, companionToken)

    assert(typeof bootstrap.appName === 'string' && bootstrap.appName.length > 0, 'Companion bootstrap did not return an app name.')
    assert(typeof bootstrap.machineName === 'string' && bootstrap.machineName.length > 0, 'Companion bootstrap did not return a friendly machine name.')
    assert(typeof bootstrap.appsCatalogUrl === 'string' && bootstrap.appsCatalogUrl.includes('apps.roachnet.org'), 'Companion bootstrap did not return the Apps catalog URL.')
    assert(Array.isArray(bootstrap.sessions), 'Companion bootstrap did not return chat sessions.')
    assert(runtime?.providers && runtime?.roachClaw, 'Companion runtime payload is missing provider or RoachClaw state.')
    assert(Array.isArray(runtime?.services), 'Companion runtime payload is missing service state.')
    assert(typeof roachtail?.deviceName === 'string' && roachtail.deviceName.length > 0, 'Companion RoachTail payload is missing the device name.')
    assert(Array.isArray(roachtail?.peers), 'Companion RoachTail payload is missing peers.')
    assert(typeof roachsync?.provider === 'string' && roachsync.provider.length > 0, 'Companion RoachSync payload is missing the provider.')
    assert(typeof roachsync?.folderPath === 'string', 'Companion RoachSync payload is missing the folder path.')
    assert(Array.isArray(vault?.knowledgeFiles), 'Companion vault payload is missing knowledge files.')
    assert(Array.isArray(vault?.roachBrain), 'Companion vault payload is missing RoachBrain records.')

    const fixturesDir = path.join(tempRoot, 'fixtures')
    mkdirSync(fixturesDir, { recursive: true })
    writeFixture(fixturesDir, 'bootstrap.json', bootstrap)
    writeFixture(fixturesDir, 'runtime.json', runtime)
    writeFixture(fixturesDir, 'roachtail.json', roachtail)
    writeFixture(fixturesDir, 'roachsync.json', roachsync)
    writeFixture(fixturesDir, 'vault.json', vault)

    console.log('Building and checking the iOS companion against the live desktop fixtures...')
    await verifyIOSFixtures(fixturesDir)

    console.log('RoachNet desktop and iOS companion compatibility is healthy.')
  } catch (error) {
    const runtimeLogs = runtimeHandle.getLogs()
    const formattedLogs = formatLogs('desktop runtime', runtimeLogs)
    if (formattedLogs) {
      console.error(formattedLogs)
    }
    throw error
  } finally {
    try {
      await runCommand(process.execPath, [path.join(repoRoot, 'scripts', 'run-roachnet.mjs'), '--stop'], {
        cwd: repoRoot,
        env: runtimeEnv,
      })
    } catch {
      // best-effort cleanup
    }

    await stopChild(runtimeHandle.child)

    if (!keepTempArtifacts) {
      await rm(tempRoot, { recursive: true, force: true })
    }
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
