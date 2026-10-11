#!/usr/bin/env node

import { execFileSync, spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import net from 'node:net'
import path from 'node:path'
import process from 'node:process'
import { randomBytes } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { requestHttp } from './lib/roachnet_http.mjs'
import { runCommand } from './lib/roachnet_child_process.mjs'
import {
  redactSensitiveObject,
  redactSensitiveText,
} from './lib/roachnet_process_security.mjs'

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
const packagedRuntimeHelperPath = path.join(desktopAppBundlePath, 'Contents', 'Helpers', 'roachnet-runtime')
const iosRepoRoot = process.env.ROACHNET_IOS_REPO
  ? path.resolve(process.env.ROACHNET_IOS_REPO)
  : path.resolve(repoRoot, '..', 'RoachNet-iOS')
const siteRepoRoot = process.env.ROACHNET_SITE_REPO
  ? path.resolve(process.env.ROACHNET_SITE_REPO)
  : path.resolve(repoRoot, '..', 'roachnet-org')
const siteCatalogPath = path.join(siteRepoRoot, 'app-store-catalog.json')
const siteMapsPath = path.join(siteRepoRoot, 'collections', 'maps.json')
const sitePacksPath = path.join(siteRepoRoot, 'collections', 'packs.json')
const keepTempArtifacts = process.env.ROACHNET_SMOKE_KEEP_TEMP === '1' || process.env.ROACHNET_KEEP_SMOKE_ARTIFACTS === '1'
const smokeWorkRoot = process.env.ROACHNET_SMOKE_TMPDIR
  ? path.resolve(process.env.ROACHNET_SMOKE_TMPDIR)
  : path.join(repoRoot, 'native', 'macos', 'dist', '.smoke-work')
const pollIntervalMs = 1_500
const startupTimeoutMs = 300_000
const supportedInstallActions = new Set([
  'base-map-assets',
  'map-collection',
  'education-tier',
  'education-resource',
  'wikipedia-option',
  'roachclaw-model',
  'roachspeech-pack',
  'roachvoice-pack',
  'direct-download',
  'pack',
])

function assert(condition, message) {
  if (!condition) {
    throw new Error(message)
  }
}

export function shouldRegenerateIOSProject(env = process.env) {
  return env.ROACHNET_REGENERATE_XCODEPROJ === '1'
}

function isCandidateBoundIOSSmoke(env = process.env) {
  return env.ROACHNET_CANDIDATE_BUILD === '1' || env.ROACHNET_RELEASE_BUILD === '1'
}

function readIOSGitOutput(iosRepoRoot, args, execFileSyncImpl) {
  try {
    return String(execFileSyncImpl('git', ['-C', iosRepoRoot, ...args], { encoding: 'utf8' })).trim()
  } catch (error) {
    const detail = error?.stderr ? String(error.stderr).trim() : error?.message || String(error)
    throw new Error(`Unable to inspect iOS companion Git state: ${detail}`)
  }
}

export function validateIOSCompanionCheckout({
  iosRepoRoot,
  projectPath = path.join(iosRepoRoot, 'RoachNetCompanion.xcodeproj'),
  env = process.env,
  existsSyncImpl = existsSync,
  execFileSyncImpl = execFileSync,
} = {}) {
  const expectedSha = String(env.ROACHNET_IOS_EXPECTED_SHA || '').trim()
  const candidateBound = isCandidateBoundIOSSmoke(env)

  if (expectedSha && !/^[a-f0-9]{40}$/i.test(expectedSha)) {
    throw new Error('ROACHNET_IOS_EXPECTED_SHA must be an exact full 40-character commit SHA.')
  }
  if (candidateBound && !expectedSha) {
    throw new Error('Candidate/release iOS companion smoke requires ROACHNET_IOS_EXPECTED_SHA to bind evidence to an exact clean checkout.')
  }
  if (!existsSyncImpl(iosRepoRoot)) {
    if (expectedSha || candidateBound) {
      throw new Error(`Candidate-bound iOS companion checkout is missing: ${iosRepoRoot}`)
    }
    return null
  }
  if (!existsSyncImpl(projectPath)) {
    throw new Error(`Missing tracked iOS project at ${projectPath}`)
  }

  const isGitRepository = readIOSGitOutput(iosRepoRoot, ['rev-parse', '--is-inside-work-tree'], execFileSyncImpl)
  if (isGitRepository !== 'true') {
    throw new Error(`iOS companion path is not a Git repository: ${iosRepoRoot}`)
  }
  readIOSGitOutput(
    iosRepoRoot,
    ['ls-files', '--error-unmatch', 'RoachNetCompanion.xcodeproj/project.pbxproj'],
    execFileSyncImpl
  )
  const sha = readIOSGitOutput(iosRepoRoot, ['rev-parse', 'HEAD'], execFileSyncImpl)
  const dirtyState = readIOSGitOutput(iosRepoRoot, ['status', '--porcelain', '--untracked-files=all'], execFileSyncImpl)

  if (expectedSha && sha !== expectedSha) {
    throw new Error(`iOS companion HEAD ${sha} does not match ROACHNET_IOS_EXPECTED_SHA ${expectedSha}.`)
  }
  if ((expectedSha || candidateBound) && dirtyState) {
    throw new Error(`iOS companion checkout must be clean for candidate-bound validation:\n${dirtyState}`)
  }

  console.log(`Using iOS companion checkout ${sha}${expectedSha ? ' (expected SHA verified)' : ' (developer diagnostic mode)'}.`)
  return { sha, candidateBound, expectedSha: expectedSha || null }
}

async function regenerateIOSProjectIfRequested({ iosRepoRoot, env = process.env, runCommandImpl = runSmokeCommand }) {
  if (!shouldRegenerateIOSProject(env)) return

  try {
    await runCommandImpl('ruby', [path.join(iosRepoRoot, 'scripts', 'generate_xcodeproj.rb')], { cwd: iosRepoRoot })
  } catch (error) {
    throw new Error(
      `iOS project regeneration is an explicit maintenance operation and requires Ruby with the xcodeproj gem available; no gems were installed automatically. ${error?.message || String(error)}`
    )
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
    sections.push(`${label} stdout:\n${redactSensitiveText(logs.stdout.trim(), process.env)}`)
  }

  if (logs?.stderr?.trim()) {
    sections.push(`${label} stderr:\n${redactSensitiveText(logs.stderr.trim(), process.env)}`)
  }

  return sections.join('\n\n')
}

async function runSmokeCommand(command, args, options = {}) {
  return await runCommand(command, args, { ...options, formatLogs })
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
      const response = await requestHttp(url, {
        headers: { Accept: 'application/json' },
        timeoutMs: 5_000,
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

  const response = await requestHttp(url, {
    method: options.method || 'GET',
    headers,
    body: options.body ? JSON.stringify(options.body) : undefined,
    timeoutMs: options.timeoutMs || 15_000,
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
  const nativeRuntime = resolveRuntimeCommand().native
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
    ...(nativeRuntime
      ? { ROACHNET_RUNTIME_KIND: 'native' }
      : { ROACHNET_NODE_BINARY: nodeBinary, ROACHNET_NPM_BINARY: npmBinary }),
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

// Prefer the native Swift runtime: an explicit build (ROACHNET_NATIVE_API_BINARY,
// e.g. native/macos/.build/release/roachnet-runtime), then the packaged helper.
// The Node launcher is only used for legacy compat checkouts.
function resolveRuntimeCommand() {
  const explicit = process.env.ROACHNET_NATIVE_API_BINARY?.trim()
  if (explicit) {
    assert(existsSync(explicit), `ROACHNET_NATIVE_API_BINARY does not exist: ${explicit}`)
    return { native: true, command: explicit, args: [] }
  }
  if (existsSync(packagedRuntimeHelperPath)) {
    return { native: true, command: packagedRuntimeHelperPath, args: [] }
  }
  const nativeLauncherPath = path.join(repoRoot, 'scripts', 'run-roachnet-native-api.mjs')
  assert(existsSync(nativeLauncherPath), 'No native runtime helper or compat launcher is available.')
  const nodeBinary = existsSync(packagedNodeBinaryPath) ? packagedNodeBinaryPath : process.execPath
  return { native: false, command: nodeBinary, args: [nativeLauncherPath] }
}

function writeFixture(directory, filename, payload) {
  const targetPath = path.join(directory, filename)
  writeFileSync(targetPath, `${JSON.stringify(redactSensitiveObject(payload, process.env), null, 2)}\n`)
  return targetPath
}

function parseServerBaseUrl(adminLogPath) {
  const content = existsSync(adminLogPath) ? readFileSync(adminLogPath, 'utf8') : ''
  const nativeMatches = [...content.matchAll(/native api listening on (https?:\/\/[^\s"]+)/g)]
  if (nativeMatches.length > 0) {
    return nativeMatches.at(-1)?.[1] || null
  }

  return null
}

function readRuntimeBaseUrl(processInfoPath) {
  try {
    const content = JSON.parse(readFileSync(processInfoPath, 'utf8'))
    const healthUrl = content?.processes?.find((entry) => entry?.name === 'native-api')?.healthUrl
    if (healthUrl) {
      return new URL('/', healthUrl).origin
    }
  } catch {
    return null
  }

  return null
}

function readCompanionBaseUrl(processInfoPath) {
  try {
    const content = JSON.parse(readFileSync(processInfoPath, 'utf8'))
    return content?.companionUrl || null
  } catch {
    return null
  }
}

function isExpectedAppsCatalogUrl(value) {
  try {
    const parsed = new URL(String(value))
    return parsed.protocol === 'https:' && parsed.username === '' && parsed.password === '' && parsed.origin === 'https://apps.roachnet.org'
  } catch {
    return false
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
    const runtimeBaseUrl = parseServerBaseUrl(adminLogPath) || readRuntimeBaseUrl(processInfoPath)
    const companionBaseUrl = readCompanionBaseUrl(processInfoPath)

    if (runtimeBaseUrl && companionBaseUrl) {
      return { runtimeBaseUrl, companionBaseUrl }
    }

    await sleep(pollIntervalMs)
  }

  return { runtimeBaseUrl: null, companionBaseUrl: null }
}

async function verifyIOSFixtures(fixturesDir) {
  const projectPath = path.join(iosRepoRoot, 'RoachNetCompanion.xcodeproj')
  const checkout = validateIOSCompanionCheckout({ iosRepoRoot, projectPath })
  if (!checkout) {
    console.warn(`Skipping developer iOS compatibility diagnostic because ${iosRepoRoot} does not exist.`)
    return
  }

  const modelPath = path.join(iosRepoRoot, 'RoachNetCompanion', 'Core', 'CompanionModels.swift')
  const derivedDataPath = path.join(fixturesDir, 'DerivedData')
  const xcodeTmpPath = path.join(fixturesDir, 'tmp')
  const checkerPath = path.join(fixturesDir, 'companion-fixture-check')
  const checkerSourcePath = path.join(fixturesDir, 'companion-fixture-check.swift')

  assert(existsSync(modelPath), `Missing iOS companion model file at ${modelPath}`)
  mkdirSync(xcodeTmpPath, { recursive: true })

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

  await regenerateIOSProjectIfRequested({ iosRepoRoot })
  validateIOSCompanionCheckout({ iosRepoRoot, projectPath })
  await runSmokeCommand(
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
      'COMPILER_INDEX_STORE_ENABLE=NO',
      'ONLY_ACTIVE_ARCH=YES',
      'ARCHS=arm64',
      '-derivedDataPath',
      derivedDataPath,
      'build',
    ],
    {
      cwd: iosRepoRoot,
      env: {
        ...process.env,
        DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer',
        COMPILER_INDEX_STORE_ENABLE: 'NO',
        ONLY_ACTIVE_ARCH: 'YES',
        ARCHS: 'arm64',
        TMPDIR: xcodeTmpPath,
      },
    }
  )

  await runSmokeCommand(
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

  await runSmokeCommand(
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
  // 1.1 catalog packs install by id from the published pack catalog, so every
  // pack item must name a pack that catalog actually lists.
  const packIds = existsSync(sitePacksPath)
    ? new Set((JSON.parse(readFileSync(sitePacksPath, 'utf8')).packs || []).map((pack) => pack.id))
    : new Set()

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
      case 'roachspeech-pack':
      case 'roachvoice-pack':
        assert(typeof intent.pack === 'string' && intent.pack.length > 0, `RoachSpeech pack ${item.id} is missing a pack id.`)
        assert(typeof intent.url === 'string' && intent.url.startsWith('http'), `RoachSpeech pack ${item.id} is missing a valid URL.`)
        modelPackCount += 1
        break
      case 'pack':
        assert(typeof intent.pack === 'string' && intent.pack.length > 0, `Pack ${item.id} is missing a pack id.`)
        assert(packIds.has(intent.pack), `Pack ${item.id} points at ${intent.pack}, which collections/packs.json does not list.`)
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
  const projectPath = path.join(iosRepoRoot, 'RoachNetCompanion.xcodeproj')
  const initialCheckout = validateIOSCompanionCheckout({ iosRepoRoot, projectPath })
  if (!initialCheckout) {
    console.warn(`Skipping developer iOS compatibility diagnostic because ${iosRepoRoot} does not exist.`)
    return
  }

  mkdirSync(smokeWorkRoot, { recursive: true })
  const tempRoot = await mkdtemp(path.join(smokeWorkRoot, 'roachnet-ios-companion-smoke-'))
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
  const runtimeCommand = resolveRuntimeCommand()
  console.log(`Runtime under test: ${runtimeCommand.native ? 'native roachnet-runtime' : 'legacy Node launcher'} (${runtimeCommand.command})`)

  const runtimeHandle = spawnProcess(runtimeCommand.command, runtimeCommand.args, {
    cwd: repoRoot,
    env: runtimeEnv,
  })

  const logsRoot = path.join(storagePath, 'logs')
  const adminLogPath = path.join(logsRoot, 'roachnet-native-api.log')
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
    assert(runtimeBaseUrl, 'Unable to resolve the contained desktop runtime URL from native runtime info.')
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
    assert(isExpectedAppsCatalogUrl(bootstrap.appsCatalogUrl), 'Companion bootstrap did not return the Apps catalog URL.')
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
      await runSmokeCommand(runtimeCommand.command, [...runtimeCommand.args, '--stop'], {
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

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  main().catch((error) => {
    console.error('RoachNet desktop/iOS companion compatibility smoke failed. Re-run with ROACHNET_SMOKE_KEEP_TEMP=1 for local diagnostic artifacts.')
    const message = error?.message || String(error)
    console.error(message.startsWith('Unable to start ') ? message : error?.stack || message)
    process.exitCode = 1
  })
}
