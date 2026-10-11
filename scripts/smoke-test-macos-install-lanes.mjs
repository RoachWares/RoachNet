#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { cp, mkdtemp, readdir, rm } from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { requestHttp } from './lib/roachnet_http.mjs'
import { applyAppleSiliconLocalAIDefaults } from './lib/roachnet_local_ai_runtime.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const distRoot = path.join(repoRoot, 'native', 'macos', 'dist')
const setupBundlePath = path.join(distRoot, 'RoachNet Setup.app')
const desktopAppBundlePath = path.join(distRoot, 'RoachNet.app')
const packagedAppArchivePath = path.join(
  setupBundlePath,
  'Contents',
  'Resources',
  'InstallerAssets',
  `RoachNet-${JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8')).version || '1.0.0'}-mac-${process.arch}.zip`
)
const packageVersion = JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8')).version || '1.0.0'
const pollIntervalMs = 1_500
const startupTimeoutMs = 600_000
const keepTempArtifacts = process.env.ROACHNET_SMOKE_KEEP_TEMP === '1'
// Defaults to the dist volume. ROACHNET_SMOKE_WORK_ROOT moves it, for example
// to the internal disk when dist sits on an external drive: a freshly signed
// RoachNet.app launched from a removable volume waits on a macOS
// "access files on a removable volume" prompt that a person has to answer.
const smokeWorkspaceRoot = process.env.ROACHNET_SMOKE_WORK_ROOT
  ? path.resolve(process.env.ROACHNET_SMOKE_WORK_ROOT)
  : path.join(distRoot, '.smoke-work')
const bundledSourceForbiddenPathPrefixes = [
  'storage/',
  'admin/storage/',
  'admin/build/storage/',
  'admin/build/tmp/',
  'admin/build/uploads/',
  'admin/build/public/uploads/',
]
const bundledSourceForbiddenPathPatterns = [
  /(^|\/)admin\/\.env\.example$/i,
  /(^|\/)MEMORY\.MD$/i,
  /(^|\/)docs\/BRAND_STYLE\.md$/i,
  /(^|\/)native\/windows\//i,
  /\.zim$/i,
  /\/vaults\.json$/i,
  /\.sqlite(?:$|[-.])/i,
  /\.db(?:$|[-.])/i,
  /\.jsonl$/i,
  /\.ndjson$/i,
  /\/roachnet-runtime-processes\.json$/i,
]

function assert(condition, message) {
  if (!condition) {
    throw new Error(message)
  }
}

function logStep(message) {
  console.log(`[smoke] ${message}`)
}

function withTaskLogs(message, task) {
  const logs = Array.isArray(task?.logs) ? task.logs.join('\n') : ''
  return logs ? `${message}\n\nSetup task logs:\n${logs}` : message
}

function parseEnvFile(content) {
  const values = {}

  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) {
      continue
    }

    const separatorIndex = line.indexOf('=')
    if (separatorIndex === -1) {
      continue
    }

    const key = line.slice(0, separatorIndex).trim()
    let value = line.slice(separatorIndex + 1).trim()

    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }

    values[key] = value
  }

  return values
}

function serializeEnvFile(values) {
  return (
    Object.entries(values)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, value]) => `${key}=${String(value)}`)
      .join('\n') + '\n'
  )
}

function readPlistStringValue(bundlePath, key) {
  const infoPlistPath = path.join(bundlePath, 'Contents', 'Info.plist')
  assert(existsSync(infoPlistPath), `Missing Info.plist at ${infoPlistPath}`)

  const content = readFileSync(infoPlistPath, 'utf8')
  const match = content.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`))
  return match?.[1]?.trim() || null
}

function readBundleVersion(bundlePath) {
  return readPlistStringValue(bundlePath, 'CFBundleShortVersionString')
}

function getBundledSourceArchivePath(bundlePath) {
  return path.join(bundlePath, 'Contents', 'Resources', 'RoachNetSource.tar.gz')
}

function getBundledSourceDirectoryPath(bundlePath) {
  return path.join(bundlePath, 'Contents', 'Resources', 'RoachNetSource')
}

function getNativeRuntimeHelperPath(bundlePath) {
  return path.join(bundlePath, 'Contents', 'Helpers', 'roachnet-runtime')
}

function bundleUsesNativeRuntime(bundlePath) {
  return existsSync(getNativeRuntimeHelperPath(bundlePath))
}

// Each runtime descriptor is { command, args, stopArgs, cwd, nodeBinary }. 1.0.6+
// bundles run the native Swift helper; legacy compat bundles run the Node launchers.
function getPackagedSetupRuntimePaths(bundlePath = setupBundlePath, bundledSourceRoot = null) {
  if (bundleUsesNativeRuntime(bundlePath)) {
    const helper = getNativeRuntimeHelperPath(bundlePath)
    return { native: true, command: helper, args: ['--setup'], cwd: path.dirname(helper), nodeBinary: null }
  }
  const sourceRoot =
    bundledSourceRoot || path.join(bundlePath, 'Contents', 'Resources', 'RoachNetSource')
  const nodeBinary = path.join(bundlePath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node', 'bin', 'node')
  const launcherPath = path.join(sourceRoot, 'scripts', 'run-roachnet-setup.mjs')
  return { native: false, command: nodeBinary, args: [launcherPath], cwd: path.dirname(launcherPath), nodeBinary }
}

function getPackagedAppRuntimePaths(appBundlePath, installRoot = null) {
  if (bundleUsesNativeRuntime(appBundlePath)) {
    const helper = getNativeRuntimeHelperPath(appBundlePath)
    return {
      native: true,
      command: helper,
      args: [],
      stopArgs: ['--stop'],
      cwd: path.dirname(helper),
      nodeBinary: null,
      alias: { command: helper, args: ['--provision-alias'], cwd: path.dirname(helper) },
    }
  }
  const sourceRoot =
    installRoot || path.join(appBundlePath, 'Contents', 'Resources', 'RoachNetSource')
  const nativeLauncherPath = path.join(sourceRoot, 'scripts', 'run-roachnet-native-api.mjs')
  assert(existsSync(nativeLauncherPath), `Missing native API launcher at ${nativeLauncherPath}`)
  const nodeBinary = path.join(appBundlePath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node', 'bin', 'node')
  const aliasInstallerPath = path.join(sourceRoot, 'scripts', 'install-roachtail-hostname.mjs')
  return {
    native: false,
    command: nodeBinary,
    args: [nativeLauncherPath],
    stopArgs: [nativeLauncherPath, '--stop'],
    cwd: path.dirname(nativeLauncherPath),
    nodeBinary,
    alias: { command: nodeBinary, args: [aliasInstallerPath, '--apply'], cwd: path.dirname(aliasInstallerPath) },
  }
}

function baseShellEnv(homePath) {
  return {
    ...process.env,
    HOME: homePath,
    USERPROFILE: homePath,
    LOGNAME: 'roachnet-smoke',
    USER: 'roachnet-smoke',
    TMPDIR: path.join(homePath, 'tmp'),
  }
}

function buildContainedRuntimeEnv({ homePath, installRoot, storagePath, config, runtime, extra = {} }) {
  const installProfile = config.installProfile || 'standard'
  const containerlessMode = config.useDockerContainerization === false ? '1' : '0'

  return applyAppleSiliconLocalAIDefaults({
    ...baseShellEnv(homePath),
    ROACHNET_STORAGE_PATH: storagePath,
    OPENCLAW_WORKSPACE_PATH: path.join(storagePath, 'openclaw'),
    OLLAMA_MODELS: path.join(storagePath, 'ollama'),
    OLLAMA_BASE_URL: 'http://127.0.0.1:36434',
    OPENCLAW_BASE_URL: 'http://127.0.0.1:13001',
    ROACHNET_RUNTIME_STATE_ROOT: path.join(storagePath, 'state', 'runtime-state'),
    ROACHNET_LOCAL_BIN_PATH: path.join(installRoot, 'bin'),
    ...(runtime.nodeBinary
      ? {
          ROACHNET_NODE_BINARY: runtime.nodeBinary,
          ROACHNET_NPM_BINARY: path.join(path.dirname(runtime.nodeBinary), 'npm'),
        }
      : { ROACHNET_RUNTIME_KIND: 'native' }),
    ROACHNET_INSTALL_PROFILE: installProfile,
    ROACHNET_BOOTSTRAP_PENDING: config.bootstrapPending ? '1' : '0',
    ROACHNET_CONTAINERLESS_MODE: containerlessMode,
    ROACHNET_DISABLE_QUEUE: containerlessMode === '1' ? '1' : '0',
    ROACHNET_ROACHCLAW_DEFAULT_MODEL: config.roachClawDefaultModel || 'qwen2.5-coder:1.5b',
    ROACHNET_INSTALLER_CONFIG_PATH: extra.ROACHNET_INSTALLER_CONFIG_PATH,
    ...extra,
  })
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
        reject(new Error('Failed to allocate a smoke-test port.'))
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

async function waitForHttpOk(url, timeoutMs) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    try {
      const response = await requestHttp(url, {
        headers: { Accept: 'application/json' },
      })

      if (response.ok) {
        return response
      }
    } catch {
      // Still booting.
    }

    await sleep(pollIntervalMs)
  }

  throw new Error(`Timed out waiting for ${url}`)
}

async function waitForRuntimeHealthUrl(processInfoPath, timeoutMs) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    try {
      const payload = JSON.parse(readFileSync(processInfoPath, 'utf8'))
      const nativeProcess = Array.isArray(payload?.processes)
        ? payload.processes.find((entry) => entry?.name === 'native-api')
        : null
      const healthUrl = nativeProcess?.healthUrl || payload?.healthUrl

      if (typeof healthUrl === 'string' && healthUrl.trim()) {
        await waitForHttpOk(healthUrl, Math.min(30_000, timeoutMs))
        return healthUrl
      }
    } catch {
      // The GUI may still be starting or rewriting the process-state file.
    }

    await sleep(pollIntervalMs)
  }

  throw new Error(`Timed out waiting for a native runtime health URL in ${processInfoPath}`)
}

async function waitForHttpUnavailable(url, timeoutMs) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    try {
      const response = await requestHttp(url, {
        headers: { Accept: 'application/json' },
        timeoutMs: 3_000,
      })

      if (!response.ok) {
        return
      }
    } catch {
      return
    }

    await sleep(500)
  }

  throw new Error(`Timed out waiting for ${url} to stop responding`)
}

async function waitForPath(targetPath, timeoutMs, label) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    if (existsSync(targetPath)) {
      return
    }

    await sleep(250)
  }

  throw new Error(`Timed out waiting for ${label || targetPath}`)
}

async function listRoachWindows() {
  const swiftScript = `
import Cocoa
import CoreGraphics

let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for row in rows {
  let owner = row[kCGWindowOwnerName as String] as? String ?? ""
  let name = row[kCGWindowName as String] as? String ?? ""
  if owner.localizedCaseInsensitiveContains("roach") || name.localizedCaseInsensitiveContains("roach") {
    let id = row[kCGWindowNumber as String] as? Int ?? 0
    let layer = row[kCGWindowLayer as String] as? Int ?? -1
    print("\\(id)|\\(owner)|\\(name)|\\(layer)")
  }
}
`.trim()

  const { stdout } = await runCommand('swift', ['-e', swiftScript], {
    stdio: 'pipe',
    timeoutMs: 60_000,
  })

  return stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [id, owner, name, layer] = line.split('|')
      return {
        id: Number.parseInt(id || '0', 10),
        owner: owner || '',
        name: name || '',
        layer: Number.parseInt(layer || '-1', 10),
      }
    })
}

async function listAutomationWindowSnapshot(processName) {
  const safeProcessName = String(processName || '').replace(/\\/g, '\\\\').replace(/"/g, '\\"')
  const appleScript = `
tell application "System Events"
  if exists process "${safeProcessName}" then
    tell process "${safeProcessName}"
      return ((count of windows) as string) & "|" & (name of every window as string)
    end tell
  end if
end tell
return "0|"
`.trim()

  try {
    const { stdout } = await runCommand('osascript', ['-e', appleScript], {
      stdio: 'pipe',
      timeoutMs: 15_000,
    })

    const raw = stdout.trim()
    if (!raw) {
      return { count: 0, names: [] }
    }

    const [countRaw = '0', namesRaw = ''] = raw.split('|', 2)
    return {
      count: Number.parseInt(countRaw || '0', 10) || 0,
      names: namesRaw
      .split(/\s*,\s*/)
      .map((name) => name.trim())
      .filter(Boolean),
    }
  } catch {
    return { count: 0, names: [] }
  }
}

function normalizeWindowLabel(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ')
}

function normalizeWindowToken(value) {
  return normalizeWindowLabel(value).replace(/[^a-z0-9]/g, '')
}

function roachWindowMatches(window, labels) {
  const normalizedWindowOwner = normalizeWindowLabel(window.owner)
  const normalizedWindowName = normalizeWindowLabel(window.name)
  const normalizedWindowOwnerToken = normalizeWindowToken(window.owner)
  const normalizedWindowNameToken = normalizeWindowToken(window.name)

  if (window.layer !== 0) {
    return false
  }

  return (
    (
      normalizedWindowOwner === labels.normalizedOwner ||
      normalizedWindowOwner === labels.normalizedProcess ||
      normalizedWindowOwnerToken === labels.ownerToken ||
      normalizedWindowOwnerToken === labels.processToken
    ) &&
    (
      // Without Screen Recording permission macOS hides window titles, so an
      // on-screen, normal-layer window owned by the app counts on its own.
      normalizedWindowName === '' ||
      normalizedWindowName === labels.normalizedTitle ||
      normalizedWindowName === labels.normalizedOwner ||
      normalizedWindowName === labels.normalizedProcess ||
      normalizedWindowNameToken === labels.titleToken ||
      normalizedWindowNameToken === labels.ownerToken ||
      normalizedWindowNameToken === labels.processToken
    )
  )
}

async function hasRoachWindow(ownerName, titleName = ownerName, processName = null) {
  const normalizedOwner = normalizeWindowLabel(ownerName)
  const normalizedTitle = normalizeWindowLabel(titleName)
  const normalizedProcess = normalizeWindowLabel(processName)
  const ownerToken = normalizeWindowToken(ownerName)
  const titleToken = normalizeWindowToken(titleName)
  const processToken = normalizeWindowToken(processName)
  const labels = {
    normalizedOwner,
    normalizedTitle,
    normalizedProcess,
    ownerToken,
    titleToken,
    processToken,
  }

  if (processName) {
    const automationWindowSnapshots = [await listAutomationWindowSnapshot(processName)]
    if (normalizedProcess && normalizedProcess !== normalizedOwner) {
      automationWindowSnapshots.push(await listAutomationWindowSnapshot(ownerName))
    }

    for (const automationWindowSnapshot of automationWindowSnapshots) {
      if (automationWindowSnapshot.count > 0) {
        return true
      }

      if (
        automationWindowSnapshot.names.some((name) => {
          const normalizedName = normalizeWindowLabel(name)
          const normalizedToken = normalizeWindowToken(name)
          return (
            normalizedName === normalizedTitle ||
            normalizedName === normalizedOwner ||
            normalizedName === normalizedProcess ||
            normalizedToken === titleToken ||
            normalizedToken === ownerToken ||
            normalizedToken === processToken ||
            (!normalizedTitle && normalizedName.length > 0)
          )
        })
      ) {
        return true
      }
    }

    const windows = await listRoachWindows()
    return windows.some((window) => roachWindowMatches(window, labels))
  }

  const windows = await listRoachWindows()
  return windows.some((window) => roachWindowMatches(window, labels))
}

async function waitForRoachWindow(ownerName, timeoutMs, titleName = ownerName, processName = null) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    if (await hasRoachWindow(ownerName, titleName, processName)) {
      return
    }

    await sleep(750)
  }

  throw new Error(`Timed out waiting for the ${ownerName} window to appear.`)
}

async function fetchJson(url, options = {}) {
  const response = await requestHttp(url, {
    headers: {
      Accept: 'application/json',
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {}),
    },
    ...options,
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

async function verifyGuiLaunch({
  appBundlePath,
  appProcessName,
  configPath = null,
  extraEnv = {},
  homePath,
  healthUrl = null,
  processInfoPath = null,
  ownerName,
  titleName = ownerName,
  windowTimeoutMs = 300_000,
}) {
  logStep(`Launching ${ownerName} from ${appBundlePath}`)
  const env = {
    ...baseShellEnv(homePath),
    ...extraEnv,
  }

  if (configPath) {
    env.ROACHNET_INSTALLER_CONFIG_PATH = configPath
  }

  await normalizeMacBundle(appBundlePath, homePath, 120_000)

  await runCommand('pkill', ['-x', appProcessName], {
    env,
    timeoutMs: 5_000,
  }).catch(() => {})

  if (processInfoPath) {
    await rm(processInfoPath, { force: true }).catch(() => {})
  }

  await runCommand('open', ['-na', appBundlePath], {
    env,
    timeoutMs: 30_000,
  })

  logStep(`Waiting for ${ownerName} window`)
  await waitForRoachWindow(ownerName, windowTimeoutMs, titleName, appProcessName)
  let resolvedHealthUrl = healthUrl
  if (!resolvedHealthUrl && processInfoPath) {
    logStep(`Waiting for ${ownerName} to advertise its native runtime health URL`)
    resolvedHealthUrl = await waitForRuntimeHealthUrl(processInfoPath, startupTimeoutMs)
  }
  if (resolvedHealthUrl) {
    logStep(`Waiting for ${ownerName} runtime health at ${resolvedHealthUrl}`)
    await waitForHttpOk(resolvedHealthUrl, startupTimeoutMs)
    await sleep(2_000)
  }

  const windowStillVisible = await hasRoachWindow(ownerName, titleName, appProcessName)
  assert(
    windowStillVisible,
    resolvedHealthUrl
      ? `${ownerName} window closed after the runtime became healthy.`
      : `${ownerName} window closed before the interface settled.`
  )

  return resolvedHealthUrl
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

async function runCommand(command, args, options = {}) {
  const child = spawn(command, args, {
    cwd: options.cwd || repoRoot,
    env: options.env || process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })

  let stdout = ''
  let stderr = ''
  let timedOut = false
  const timeoutHandle =
    options.timeoutMs && options.timeoutMs > 0
      ? setTimeout(() => {
          timedOut = true
          child.kill('SIGKILL')
        }, options.timeoutMs)
      : null

  child.stdout?.on('data', (chunk) => {
    stdout += chunk.toString()
  })
  child.stderr?.on('data', (chunk) => {
    stderr += chunk.toString()
  })

  return await new Promise((resolve, reject) => {
    child.once('error', reject)
    child.once('close', (code) => {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }

      if (timedOut) {
        reject(new Error(`${command} ${args.join(' ')} timed out after ${options.timeoutMs}ms\n${stderr}`))
        return
      }

      if (code === 0) {
        resolve({ stdout, stderr })
        return
      }

      reject(new Error(`${command} ${args.join(' ')} failed with exit code ${code}\n${stderr || stdout}`))
    })
  })
}

async function terminateLingeringSmokeProcesses() {
  const workRoots = ['/native/macos/dist/.smoke-work']
  if (process.env.ROACHNET_SMOKE_WORK_ROOT) {
    workRoots.push(path.resolve(process.env.ROACHNET_SMOKE_WORK_ROOT).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
  }
  const cleanupPatterns = workRoots.flatMap((root) => [
    `${root}/.*/Contents/Helpers/roachnet-runtime`,
    `${root}/.*/run-roachnet-setup.mjs`,
    `${root}/.*/run-roachnet-native-api.mjs`,
    `${root}/.*/run-roachnet.mjs`,
    `${root}/.*/roachnet-companion-server.mjs`,
    `${root}/.*/runtime-cache/.*/bin/server.js`,
    `${root}/.*/RoachNet\\.app/Contents/MacOS/RoachNetApp`,
    `${root}/.*/RoachNet Setup\\.app/Contents/MacOS/RoachNetSetup`,
  ])
  for (const pattern of cleanupPatterns) {
    await runCommand('pkill', ['-f', pattern], {
      timeoutMs: 5_000,
    }).catch(() => {})
  }
}

async function normalizeMacBundle(bundlePath, homePath, timeoutMs = startupTimeoutMs) {
  const env = baseShellEnv(homePath)
  const targets = [bundlePath]
  const executableRoot = path.join(bundlePath, 'Contents', 'MacOS')
  const recursiveTimeoutMs = Math.max(timeoutMs, 300_000)

  for (const args of [
    ['-dr', 'com.apple.provenance', bundlePath],
    ['-dr', 'com.apple.quarantine', bundlePath],
    ['-cr', bundlePath],
  ]) {
    await runCommand('xattr', args, {
      env,
      timeoutMs: recursiveTimeoutMs,
    }).catch(() => {})
  }

  try {
    const executableEntries = await readdir(executableRoot, { withFileTypes: true })
    for (const entry of executableEntries) {
      if (entry.isFile()) {
        targets.push(path.join(executableRoot, entry.name))
      }
    }
  } catch {
    // Keep launch normalization best-effort.
  }

  for (const targetPath of targets) {
    await runCommand('xattr', ['-d', 'com.apple.quarantine', targetPath], {
      env,
      timeoutMs: 15_000,
    }).catch(() => {})

    await runCommand('xattr', ['-d', 'com.apple.provenance', targetPath], {
      env,
      timeoutMs: 15_000,
    }).catch(() => {})
  }
}

function formatProcessLogs(label, logs) {
  const stdout = logs?.stdout?.trim()
  const stderr = logs?.stderr?.trim()
  const sections = []

  if (stdout) {
    sections.push(`${label} stdout:\n${stdout}`)
  }

  if (stderr) {
    sections.push(`${label} stderr:\n${stderr}`)
  }

  return sections.join('\n\n')
}

async function stopChild(child, signal = 'SIGTERM') {
  if (!child || child.killed || child.exitCode !== null) {
    return
  }

  child.kill(signal)
  await Promise.race([
    new Promise((resolve) => child.once('close', resolve)),
    sleep(5_000),
  ])

  if (child.exitCode === null) {
    child.kill('SIGKILL')
  }
}

async function safeRemoveTree(targetPath) {
  if (keepTempArtifacts) {
    console.log(`Preserving smoke artifacts at ${targetPath}`)
    return
  }

  for (let attempt = 0; attempt < 5; attempt += 1) {
    try {
      await rm(targetPath, {
        recursive: true,
        force: true,
        maxRetries: 3,
        retryDelay: 250,
      })
      return
    } catch (error) {
      if (attempt + 1 >= 5) {
        throw error
      }

      await sleep(500)
    }
  }
}

async function makeVolumeLocalTempRoot(prefix) {
  mkdirSync(smokeWorkspaceRoot, { recursive: true })
  return mkdtemp(path.join(smokeWorkspaceRoot, prefix))
}

async function makeSystemTempRoot(prefix) {
  return mkdtemp(path.join(os.tmpdir(), prefix))
}

async function extractTarArchive(archivePath, destinationPath) {
  mkdirSync(destinationPath, { recursive: true })
  await runCommand('tar', ['-xzf', archivePath, '-C', destinationPath], {
    timeoutMs: startupTimeoutMs,
  })
}

async function collectRelativePaths(rootPath, currentPath = rootPath) {
  const entries = await readdir(currentPath, { withFileTypes: true })
  const results = []

  for (const entry of entries) {
    const entryPath = path.join(currentPath, entry.name)
    const relativePath = path.relative(rootPath, entryPath).replaceAll(path.sep, '/')
    results.push(relativePath)

    if (entry.isDirectory()) {
      results.push(...(await collectRelativePaths(rootPath, entryPath)))
    }
  }

  return results
}

async function assertBundledSourceTreeIsReleaseSafe(rootPath) {
  const relativePaths = await collectRelativePaths(rootPath)
  const suspiciousPaths = relativePaths.filter(
    (relativePath) =>
      bundledSourceForbiddenPathPrefixes.some((prefix) => relativePath.startsWith(prefix)) ||
      bundledSourceForbiddenPathPatterns.some((pattern) => pattern.test(relativePath))
  )

  assert(
    suspiciousPaths.length === 0,
    `Bundled source tree is carrying local runtime or indexed-content artifacts:\n${suspiciousPaths
      .slice(0, 20)
      .join('\n')}`
  )
}

async function materializeBundledSourceTree(bundlePath, destinationRoot) {
  const sourceDirectoryPath = getBundledSourceDirectoryPath(bundlePath)
  if (existsSync(sourceDirectoryPath)) {
    await assertBundledSourceTreeIsReleaseSafe(sourceDirectoryPath)
    await cp(sourceDirectoryPath, destinationRoot, {
      recursive: true,
      force: true,
    })
    return
  }

  const archivePath = getBundledSourceArchivePath(bundlePath)
  assert(existsSync(archivePath), `Missing bundled source archive at ${archivePath}`)

  const extractionRoot = await makeVolumeLocalTempRoot('roachnet-source-extract-')

  try {
    await extractTarArchive(archivePath, extractionRoot)
    const extractedRoot = path.join(extractionRoot, 'RoachNetSource')
    assert(existsSync(extractedRoot), `Bundled source archive did not unpack a RoachNetSource root from ${archivePath}`)
    await assertBundledSourceTreeIsReleaseSafe(extractedRoot)
    await cp(extractedRoot, destinationRoot, {
      recursive: true,
      force: true,
    })
  } finally {
    await safeRemoveTree(extractionRoot)
  }
}

async function verifyBundleVersions() {
  logStep('Verifying packaged bundle versions')
  const bundles = [
    ['RoachNet', path.join(distRoot, 'RoachNet.app')],
    ['RoachNet Setup', setupBundlePath],
  ]

  for (const [label, bundlePath] of bundles) {
    assert(existsSync(bundlePath), `Missing ${label} bundle at ${bundlePath}`)
    const version = readBundleVersion(bundlePath)
    assert(
      version === packageVersion,
      `${label} bundle version mismatch. Expected ${packageVersion}, found ${version || 'missing'} at ${bundlePath}`
    )
    if (bundleUsesNativeRuntime(bundlePath)) {
      const helper = getNativeRuntimeHelperPath(bundlePath)
      const result = await runCommand(helper, ['--version'], { env: process.env, timeoutMs: 10_000 })
      const helperVersion = String(result?.stdout ?? '').trim()
      assert(
        helperVersion === packageVersion,
        `${label} roachnet-runtime reports ${helperVersion || 'nothing'}, expected ${packageVersion}`
      )
    }
  }

  assert(
    existsSync(packagedAppArchivePath),
    `Missing InstallerAssets RoachNet archive at ${packagedAppArchivePath}`
  )
}

async function waitForSetupTask(setupBaseUrl) {
  const stateUrl = new URL('/api/state', setupBaseUrl).toString()
  const startedAt = Date.now()

  while (Date.now() - startedAt < startupTimeoutMs) {
    const state = await fetchJson(stateUrl)
    const task = state.activeTask || state.lastCompletedTask

    if (task?.status === 'completed') {
      return task
    }

    if (task?.status === 'failed') {
      const logs = Array.isArray(task.logs) ? task.logs.join('\n') : ''
      throw new Error(`Setup lane failed: ${task.error || 'unknown error'}\n${logs}`)
    }

    await sleep(pollIntervalMs)
  }

  throw new Error(`Timed out waiting for setup task completion at ${stateUrl}`)
}

async function stopContainedRuntime({
  label,
  homePath,
  installRoot,
  storagePath,
  runtime,
  config,
  configPath,
  runtimeStateRoot,
  healthUrl,
}) {
  try {
    const stopProcess = spawnProcess(runtime.command, runtime.stopArgs, {
      cwd: runtime.cwd,
      env: buildContainedRuntimeEnv({
        homePath,
        installRoot,
        storagePath,
        runtime,
        config,
        extra: {
          ROACHNET_INSTALLER_CONFIG_PATH: configPath,
          ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
        },
      }),
    })
    await Promise.race([new Promise((resolve) => stopProcess.child.once('close', resolve)), sleep(15_000)])
    await stopChild(stopProcess.child)
  } catch {
    // Fall through to the more targeted cleanup below.
  }

  const cleanupPatterns = [
    `${installRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}.*/Contents/Helpers/roachnet-runtime`,
    `${installRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}.*/run-roachnet-native-api\\.mjs`,
    `${installRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}.*/run-roachnet\\.mjs`,
    `${installRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}.*/roachnet-companion-server\\.mjs`,
    `${installRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}.*/runtime-cache/.*/bin/server\\.js`,
  ]

  for (const pattern of cleanupPatterns) {
    await runCommand('pkill', ['-f', pattern], {
      env: baseShellEnv(homePath),
      timeoutMs: 5_000,
    }).catch(() => {})
  }

  if (healthUrl) {
    await waitForHttpUnavailable(healthUrl, 30_000)
  }

  const processInfoPath = path.join(storagePath, 'logs', 'roachnet-runtime-processes.json')
  if (existsSync(processInfoPath)) {
    await sleep(1_000)
  }

  logStep(`${label} runtime stopped cleanly before the next lane`)
}

async function smokeSetupLane() {
  logStep('Starting setup-app install smoke')
  const tempRoot = await makeVolumeLocalTempRoot('roachnet-setup-smoke-')
  const homeRoot = await makeSystemTempRoot('roachnet-setup-home-')
  const homePath = path.join(homeRoot, 'home')
  const sharedAppDataDir = path.join(homePath, 'Library', 'Application Support', 'roachnet')
  const configPath = path.join(sharedAppDataDir, 'roachnet-installer.json')
  const installRoot = path.join(tempRoot, 'installed', 'RoachNet')
  const installAppPath = path.join(installRoot, 'app', 'RoachNet.app')
  const storagePath = path.join(installRoot, 'storage')
  const setupPort = await resolveAvailablePort()
  const setupBaseUrl = `http://127.0.0.1:${setupPort}`
  const mockHostsPath = path.join(tempRoot, 'mock-hosts')

  mkdirSync(homePath, { recursive: true })
  mkdirSync(path.join(homePath, 'tmp'), { recursive: true })
  mkdirSync(path.dirname(installRoot), { recursive: true })
  writeFileSync(mockHostsPath, '127.0.0.1 localhost\n::1 localhost\n', 'utf8')

  await verifyGuiLaunch({
    appBundlePath: setupBundlePath,
    appProcessName: 'RoachNetSetup',
    homePath,
    ownerName: 'RoachNet Setup',
    windowTimeoutMs: 300_000,
  })

  logStep('Setup app window verified; switching to headless setup backend lane')
  await runCommand('pkill', ['-x', 'RoachNetSetup'], {
    env: baseShellEnv(homePath),
    timeoutMs: 5_000,
  }).catch(() => {})
  for (const pattern of ['run-roachnet-setup.mjs', 'Contents/Helpers/roachnet-runtime --setup']) {
    await runCommand('pkill', ['-f', pattern], {
      env: baseShellEnv(homePath),
      timeoutMs: 5_000,
    }).catch(() => {})
  }

  let extractedSetupSourceRoot = null
  if (!bundleUsesNativeRuntime(setupBundlePath)) {
    extractedSetupSourceRoot = path.join(tempRoot, 'setup-source')
    logStep('Materializing setup bundled source tree (legacy Node compat bundle)')
    await materializeBundledSourceTree(setupBundlePath, extractedSetupSourceRoot)
  }

  const setupRuntime = getPackagedSetupRuntimePaths(setupBundlePath, extractedSetupSourceRoot)
  logStep(`Setup backend: ${setupRuntime.native ? 'native roachnet-runtime --setup' : 'legacy Node launcher'}`)

  const setupProcess = spawnProcess(setupRuntime.command, setupRuntime.args, {
    cwd: setupRuntime.cwd,
    env: {
      ...baseShellEnv(homePath),
      ROACHNET_SETUP_NO_BROWSER: '1',
      ROACHNET_SETUP_APP_BUNDLE: setupBundlePath,
      ROACHNET_SETUP_PORT: String(setupPort),
      ROACHNET_INSTALLER_CONFIG_PATH: configPath,
      ROACHNET_SHARED_APP_DATA_DIR: sharedAppDataDir,
      ROACHNET_APP_VERSION: packageVersion,
      ROACHNET_HOSTS_FILE: mockHostsPath,
      ROACHNET_REQUIRE_LOCAL_ALIAS: '1',
    },
  })

  try {
    logStep(`Waiting for setup backend state at ${setupBaseUrl}/api/state`)
    await waitForHttpOk(new URL('/api/state', setupBaseUrl).toString(), startupTimeoutMs)

    logStep('Submitting contained install request through setup backend')
    await fetchJson(new URL('/api/install', setupBaseUrl).toString(), {
      method: 'POST',
      body: JSON.stringify({
        installPath: installRoot,
        installedAppPath: installAppPath,
        storagePath,
        installRoachClaw: false,
        useDockerContainerization: false,
        autoLaunch: false,
        autoInstallDependencies: false,
        sourceMode: 'bundled',
      }),
    })

    logStep('Waiting for setup task completion')
    const task = await waitForSetupTask(setupBaseUrl)
    assert(task.result?.appPath === installAppPath, 'Setup lane completed without the expected app target path.')
    assert(existsSync(installAppPath), `Setup lane did not install the native app at ${installAppPath}`)
    if (setupRuntime.native) {
      assert(
        existsSync(getNativeRuntimeHelperPath(installAppPath)),
        'Setup lane did not install the native roachnet-runtime helper inside RoachNet.app.'
      )
      assert(
        !existsSync(path.join(installAppPath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node')),
        'Setup lane installed an app that still embeds Node.'
      )
    } else {
      assert(existsSync(path.join(installRoot, 'scripts', 'run-roachnet-native-api.mjs')), 'Setup lane did not promote the native API runtime tree.')
    }
    assert(
      readFileSync(mockHostsPath, 'utf8').includes('127.0.0.1 RoachNet'),
      withTaskLogs(
        'Setup lane did not provision the RoachTail local alias in the mock hosts file.',
        task
      )
    )

    const installedRuntime = getPackagedAppRuntimePaths(installAppPath, installRoot)
    const installedRuntimePort = await resolveAvailablePort()
    const installedEnvValues = {
      HOST: '127.0.0.1',
      PORT: String(installedRuntimePort),
      URL: `http://127.0.0.1:${installedRuntimePort}`,
    }
    const runtimeStateRoot = path.join(storagePath, 'state', 'runtime-state')
    const launcher = spawnProcess(installedRuntime.command, installedRuntime.args, {
      cwd: installedRuntime.cwd,
      env: buildContainedRuntimeEnv({
        homePath,
        installRoot,
        storagePath,
        runtime: installedRuntime,
        config: {
          installProfile: 'setup-app',
          useDockerContainerization: false,
          bootstrapPending: false,
          roachClawDefaultModel: 'qwen2.5-coder:1.5b',
        },
        extra: {
          ...installedEnvValues,
          ROACHNET_NO_BROWSER: '1',
          ROACHNET_INSTALLER_CONFIG_PATH: configPath,
          ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
        },
      }),
    })

    try {
      logStep('Waiting for installed runtime health from the contained setup lane')
      const healthUrl = new URL('/api/health', installedEnvValues.URL || 'http://127.0.0.1:8080').toString()
      await waitForHttpOk(healthUrl, startupTimeoutMs)
      await waitForPath(
        path.join(storagePath, 'logs', 'roachnet-runtime-processes.json'),
        10_000,
        'the setup-installed runtime process-state file'
      )
    } catch (error) {
      const processLogs = formatProcessLogs('setup-installed launcher', launcher.getLogs())
      throw new Error([error.message, processLogs].filter(Boolean).join('\n\n'))
    } finally {
      try {
        const stopProcess = spawnProcess(installedRuntime.command, installedRuntime.stopArgs, {
          cwd: installedRuntime.cwd,
          env: buildContainedRuntimeEnv({
            homePath,
            installRoot,
            storagePath,
            runtime: installedRuntime,
            config: {
              installProfile: 'setup-app',
              useDockerContainerization: false,
              bootstrapPending: false,
              roachClawDefaultModel: 'qwen2.5-coder:1.5b',
            },
            extra: {
              ...installedEnvValues,
              ROACHNET_INSTALLER_CONFIG_PATH: configPath,
              ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
            },
          }),
        })
        await Promise.race([new Promise((resolve) => stopProcess.child.once('close', resolve)), sleep(15_000)])
        await stopChild(stopProcess.child)
      } catch {
        // Ignore shutdown errors in cleanup.
      }

      await stopChild(launcher.child)
    }

    const guiProcessInfoPath = path.join(storagePath, 'logs', 'roachnet-runtime-processes.json')
    const guiHealthUrl = await verifyGuiLaunch({
      appBundlePath: installAppPath,
      appProcessName: 'RoachNetApp',
      configPath,
      homePath,
      processInfoPath: guiProcessInfoPath,
      ownerName: 'RoachNet',
    })
    logStep('Installed native app stayed open after runtime became healthy')

    await runCommand('pkill', ['-x', 'RoachNetApp'], {
      env: baseShellEnv(homePath),
      timeoutMs: 5_000,
    }).catch(() => {})

    await stopContainedRuntime({
      label: 'Setup-installed',
      homePath,
      installRoot,
      storagePath,
      runtime: installedRuntime,
      config: {
        installProfile: 'setup-app',
        useDockerContainerization: false,
        bootstrapPending: false,
        roachClawDefaultModel: 'qwen2.5-coder:1.5b',
      },
      configPath,
      runtimeStateRoot,
      healthUrl: guiHealthUrl,
    })
  } catch (error) {
    const processLogs = formatProcessLogs('setup backend', setupProcess.getLogs())
    throw new Error([error.message, processLogs].filter(Boolean).join('\n\n'))
  } finally {
    await stopChild(setupProcess.child)
    await safeRemoveTree(homeRoot)
    await safeRemoveTree(tempRoot)
  }
}

async function smokeHomebrewLane() {
  logStep('Starting Homebrew-style install smoke')
  const tempRoot = await makeVolumeLocalTempRoot('roachnet-homebrew-smoke-')
  const homeRoot = await makeSystemTempRoot('roachnet-homebrew-home-')
  const homePath = path.join(homeRoot, 'home')
  const installRoot = path.join(homePath, 'RoachNet')
  const appPath = path.join(installRoot, 'app', 'RoachNet.app')
  const storagePath = path.join(installRoot, 'storage')
  const logsPath = path.join(storagePath, 'logs')
  const sharedAppDataDir = path.join(homePath, 'Library', 'Application Support', 'roachnet')
  const configPath = path.join(sharedAppDataDir, 'roachnet-installer.json')
  const legacyConfigPath = path.join(homePath, '.roachnet-setup.json')
  const mockHostsPath = path.join(tempRoot, 'mock-hosts')

  mkdirSync(homePath, { recursive: true })
  mkdirSync(path.join(homePath, 'tmp'), { recursive: true })
  mkdirSync(path.dirname(appPath), { recursive: true })
  mkdirSync(storagePath, { recursive: true })
  mkdirSync(path.join(installRoot, 'bin'), { recursive: true })
  mkdirSync(sharedAppDataDir, { recursive: true })
  writeFileSync(mockHostsPath, '127.0.0.1 localhost\n::1 localhost\n', 'utf8')

  await cp(desktopAppBundlePath, appPath, {
    recursive: true,
    force: true,
  })
  await normalizeMacBundle(appPath, homePath)
  if (!bundleUsesNativeRuntime(appPath)) {
    await materializeBundledSourceTree(appPath, installRoot)
  }
  logStep('Prepared contained Homebrew install tree')

  const config = {
    installPath: installRoot,
    installedAppPath: appPath,
    storagePath,
    installProfile: 'homebrew-cask',
    useDockerContainerization: false,
    installRoachClaw: true,
    companionEnabled: false,
    companionHost: '127.0.0.1',
    companionPort: 38111,
    companionToken: 'smoke-test-token',
    companionAdvertisedURL: '',
    roachClawDefaultModel: 'qwen2.5-coder:1.5b',
    distributedInferenceBackend: 'disabled',
    exoBaseUrl: 'http://127.0.0.1:52415',
    exoModelId: '',
    autoInstallDependencies: false,
    autoLaunch: true,
    releaseChannel: 'stable',
    setupCompletedAt: new Date().toISOString(),
    bootstrapPending: true,
    bootstrapFailureCount: 0,
    lastRuntimeHealthAt: null,
    pendingLaunchIntro: false,
    pendingRoachClawSetup: true,
  }

  writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n', 'utf8')
  writeFileSync(legacyConfigPath, JSON.stringify(config, null, 2) + '\n', 'utf8')

  const runtime = getPackagedAppRuntimePaths(appPath, installRoot)
  const aliasInstaller = spawnProcess(runtime.alias.command, runtime.alias.args, {
    cwd: runtime.alias.cwd,
    env: {
      ...baseShellEnv(homePath),
      ROACHNET_HOSTS_FILE: mockHostsPath,
      ROACHNET_LOCAL_HOSTNAME: 'RoachNet',
    },
  })

  const aliasExitCode = await new Promise((resolve) => {
    aliasInstaller.child.once('exit', (code) => resolve(code ?? 0))
  })

  assert(aliasExitCode === 0, `Homebrew alias installer failed.\n${formatProcessLogs('homebrew alias installer', aliasInstaller.getLogs())}`)
  assert(
    readFileSync(mockHostsPath, 'utf8').includes('127.0.0.1 RoachNet'),
    'Homebrew lane did not provision the RoachTail local alias in the mock hosts file.'
  )

  const adminPort = await resolveAvailablePort()
  const envValues = {
    HOST: '127.0.0.1',
    PORT: String(adminPort),
    URL: `http://127.0.0.1:${adminPort}`,
  }
  const healthUrl = new URL('/api/health', envValues.URL || 'http://127.0.0.1:8080').toString()
  const runtimeStateRoot = path.join(storagePath, 'state', 'runtime-state')

  const launcher = spawnProcess(runtime.command, runtime.args, {
    cwd: runtime.cwd,
    env: buildContainedRuntimeEnv({
      homePath,
      installRoot,
      storagePath,
      runtime,
      config,
      extra: {
        ...envValues,
        ROACHNET_NO_BROWSER: '1',
        ROACHNET_INSTALLER_CONFIG_PATH: configPath,
        ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
      },
    }),
  })

  try {
    logStep(`Waiting for Homebrew runtime health at ${healthUrl}`)
    await waitForHttpOk(healthUrl, startupTimeoutMs)
    await waitForPath(
      path.join(logsPath, 'roachnet-runtime-processes.json'),
      10_000,
      'the Homebrew runtime process-state file'
    )
  } catch (error) {
    const processLogs = formatProcessLogs('homebrew launcher', launcher.getLogs())
    throw new Error([error.message, processLogs].filter(Boolean).join('\n\n'))
  } finally {
    await stopContainedRuntime({
      label: 'Homebrew',
      homePath,
      installRoot,
      storagePath,
      runtime,
      config,
      configPath,
      runtimeStateRoot,
      healthUrl,
    }).catch(() => {})
    await stopChild(launcher.child)
  }

  let guiHealthUrl = null
  try {
    guiHealthUrl = await verifyGuiLaunch({
      appBundlePath: appPath,
      appProcessName: 'RoachNetApp',
      configPath,
      homePath,
      processInfoPath: path.join(logsPath, 'roachnet-runtime-processes.json'),
      ownerName: 'RoachNet',
    })
    logStep('Homebrew-installed app stayed open after runtime became healthy')
  } finally {
    await runCommand('pkill', ['-x', 'RoachNetApp'], {
      env: baseShellEnv(homePath),
      timeoutMs: 5_000,
    }).catch(() => {})
    await stopContainedRuntime({
      label: 'Homebrew-installed',
      homePath,
      installRoot,
      storagePath,
      runtime,
      config,
      configPath,
      runtimeStateRoot,
      healthUrl: guiHealthUrl || healthUrl,
    }).catch(() => {})
    await safeRemoveTree(homeRoot)
    await safeRemoveTree(tempRoot)
  }
}

async function main() {
  assert(process.platform === 'darwin', 'This smoke test only runs on macOS.')
  await terminateLingeringSmokeProcesses()
  await verifyBundleVersions()
  await smokeSetupLane()
  await smokeHomebrewLane()
  console.log('RoachNet macOS setup and Homebrew install lanes are healthy.')
}

main().catch((error) => {
  console.error(error.message)
  process.exitCode = 1
})
