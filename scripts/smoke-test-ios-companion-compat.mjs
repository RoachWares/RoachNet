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
const desktopAppBundlePath = path.join(repoRoot, 'native', 'macos', 'dist', 'RoachNet.app')
const packagedNodeBinaryPath = path.join(
  desktopAppBundlePath,
  'Contents',
  'Resources',
  'EmbeddedRuntime',
  'node',
  'bin',
  'node'
)
const packagedNpmBinaryPath = path.join(
  desktopAppBundlePath,
  'Contents',
  'Resources',
  'EmbeddedRuntime',
  'node',
  'bin',
  'npm'
)
const iosRepoRoot = process.env.ROACHNET_IOS_REPO
  ? path.resolve(process.env.ROACHNET_IOS_REPO)
  : path.resolve(repoRoot, '..', 'RoachNet-iOS')
const siteRepoRoot = process.env.ROACHNET_SITE_REPO
  ? path.resolve(process.env.ROACHNET_SITE_REPO)
  : path.resolve(repoRoot, '..', 'roachnet-org')
const siteCatalogPath = path.join(siteRepoRoot, 'app-store-catalog.json')
const siteMapsPath = path.join(siteRepoRoot, 'collections', 'maps.json')
const keepTempArtifacts = process.env.ROACHNET_SMOKE_KEEP_TEMP === '1'
const pollIntervalMs = 1_500
const startupTimeoutMs = 300_000
const supportedInstallActions = new Set([
  'base-map-assets',
  'map-collection',
  'education-tier',
  'education-resource',
  'wikipedia-option',
  'roachclaw-model',
  'direct-download',
])

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

async function waitForPath(targetPath, timeoutMs, label = targetPath, options = {}) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    if (existsSync(targetPath)) {
      return
    }

    if (options.child && options.child.exitCode !== null) {
      const logs = typeof options.logsProvider === 'function' ? options.logsProvider() : null
      throw new Error(
        formatLogs(
          `runtime exited before ${label}`,
          logs
        ) || `Runtime exited before ${label} was written.`
      )
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
  const nodeBinary = existsSync(packagedNodeBinaryPath) ? packagedNodeBinaryPath : process.execPath
  const npmBinary = existsSync(packagedNpmBinaryPath) ? packagedNpmBinaryPath : 'npm'

  return {
    ...process.env,
    HOME: homePath,
    USERPROFILE: homePath,
    LOGNAME: 'roachnet-companion-smoke',
    USER: 'roachnet-companion-smoke',
    TMPDIR: path.join(homePath, 'tmp'),
    HOST: '127.0.0.1',
    PORT: String(runtimePort),
    URL: `http://127.0.0.1:${runtimePort}`,
    ROACHNET_STORAGE_PATH: storagePath,
    OPENCLAW_WORKSPACE_PATH: path.join(storagePath, 'openclaw'),
    OLLAMA_MODELS: path.join(storagePath, 'ollama'),
    OLLAMA_BASE_URL: 'http://127.0.0.1:36434',
    OPENCLAW_BASE_URL: 'http://127.0.0.1:13001',
    ROACHNET_RUNTIME_STATE_ROOT: path.join(storagePath, 'state', 'runtime-state'),
    ROACHNET_LOCAL_BIN_PATH: localBinRoot,
    ROACHNET_NODE_BINARY: nodeBinary,
    ROACHNET_NPM_BINARY: npmBinary,
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
  try {
    const content = JSON.parse(readFileSync(processInfoPath, 'utf8'))
    return content?.companionUrl || null
  } catch {
    return null
  }
}

async function waitForRuntimeEndpoints({
  adminLogPath,
  processInfoPath,
  launcherLogsProvider,
  timeoutMs,
}) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    const runtimeBaseUrl = parseServerBaseUrl(
      adminLogPath,
      typeof launcherLogsProvider === 'function' ? launcherLogsProvider() : ''
    )
    const companionBaseUrl = readCompanionBaseUrl(processInfoPath)

    if (runtimeBaseUrl && companionBaseUrl) {
      return { runtimeBaseUrl, companionBaseUrl }
    }

    await sleep(pollIntervalMs)
  }

  return { runtimeBaseUrl: null, companionBaseUrl: null }
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

function validateAppsCatalogContract() {
  assert(existsSync(siteCatalogPath), `Missing Apps catalog at ${siteCatalogPath}`)
  assert(existsSync(siteMapsPath), `Missing Maps manifest at ${siteMapsPath}`)

  const catalog = JSON.parse(readFileSync(siteCatalogPath, 'utf8'))
  const mapsManifest = JSON.parse(readFileSync(siteMapsPath, 'utf8'))
  const mapSlugs = new Set((mapsManifest.collections || []).map((collection) => collection.slug))

  assert(Array.isArray(catalog.items) && catalog.items.length > 0, 'Apps catalog is empty.')

  let mapPackCount = 0
  let modelPackCount = 0

  for (const item of catalog.items) {
    const intent = item?.installIntent
    assert(intent && typeof intent === 'object', `Catalog item ${item?.id || 'unknown'} is missing installIntent.`)
    assert(
      supportedInstallActions.has(intent.action),
      `Catalog item ${item.id} uses unsupported install action ${intent.action || 'missing'}.`
    )

    switch (intent.action) {
      case 'base-map-assets':
        mapPackCount += 1
        break
      case 'map-collection':
        assert(typeof intent.slug === 'string' && intent.slug.length > 0, `Map collection ${item.id} is missing its slug.`)
        assert(mapSlugs.has(intent.slug), `Map collection ${item.id} points at unknown slug ${intent.slug}.`)
        mapPackCount += 1
        break
      case 'direct-download':
        assert(typeof intent.url === 'string' && intent.url.startsWith('http'), `Direct download ${item.id} is missing a valid URL.`)
        if (item.category === 'Maps' || item.section === 'Map Picks' || item.section === 'Map Regions') {
          assert(
            typeof intent.filetype === 'string' && ['map', 'pmtiles'].includes(intent.filetype.toLowerCase()),
            `Map download ${item.id} must declare a map-compatible filetype.`
          )
          mapPackCount += 1
        }
        break
      case 'education-tier':
        assert(typeof intent.category === 'string' && intent.category.length > 0, `Education tier ${item.id} is missing category.`)
        assert(typeof intent.tier === 'string' && intent.tier.length > 0, `Education tier ${item.id} is missing tier.`)
        break
      case 'education-resource':
        assert(typeof intent.category === 'string' && intent.category.length > 0, `Education resource ${item.id} is missing category.`)
        assert(typeof intent.resource === 'string' && intent.resource.length > 0, `Education resource ${item.id} is missing resource id.`)
        break
      case 'wikipedia-option':
        assert(typeof intent.option === 'string' && intent.option.length > 0, `Wikipedia option ${item.id} is missing option id.`)
        break
      case 'roachclaw-model':
        assert(typeof intent.model === 'string' && intent.model.length > 0, `Model pack ${item.id} is missing a model id.`)
        modelPackCount += 1
        break
      default:
        break
    }
  }

  assert(mapPackCount > 0, 'Apps catalog does not expose any map packs.')
  assert(modelPackCount > 0, 'Apps catalog does not expose any model packs.')

  return {
    itemCount: catalog.items.length,
    mapPackCount,
    modelPackCount,
  }
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
  const runtimeNodeBinary = runtimeEnv.ROACHNET_NODE_BINARY || process.execPath

  const runtimeHandle = spawnProcess(runtimeNodeBinary, [path.join(repoRoot, 'scripts', 'run-roachnet.mjs')], {
    cwd: repoRoot,
    env: runtimeEnv,
  })

  const logsRoot = path.join(storagePath, 'logs')
  const adminLogPath = path.join(logsRoot, 'admin.log')
  const processInfoPath = path.join(logsRoot, 'roachnet-runtime-processes.json')

  try {
    console.log('Waiting for contained desktop runtime health...')
    await waitForPath(adminLogPath, startupTimeoutMs, 'runtime admin log', {
      child: runtimeHandle.child,
      logsProvider: () => runtimeHandle.getLogs(),
    })
    await waitForPath(processInfoPath, startupTimeoutMs, 'runtime process info', {
      child: runtimeHandle.child,
      logsProvider: () => runtimeHandle.getLogs(),
    })

    const { runtimeBaseUrl, companionBaseUrl } = await waitForRuntimeEndpoints({
      adminLogPath,
      processInfoPath,
      launcherLogsProvider: () => runtimeHandle.getLogs().stdout,
      timeoutMs: startupTimeoutMs,
    })
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
    const catalogContract = validateAppsCatalogContract()

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

    console.log(
      `Validated Apps catalog contract against desktop install actions (${catalogContract.itemCount} items, ${catalogContract.mapPackCount} map packs, ${catalogContract.modelPackCount} model packs).`
    )
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
      await runCommand(runtimeNodeBinary, [path.join(repoRoot, 'scripts', 'run-roachnet.mjs'), '--stop'], {
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
