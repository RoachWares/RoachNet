#!/usr/bin/env node

import http from 'node:http'
import { spawn } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { chmod, copyFile, cp, mkdtemp, readFile, readdir, rename, rm, stat, statfs, symlink } from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { pipeline } from 'node:stream/promises'
import { Readable } from 'node:stream'
import { fileURLToPath } from 'node:url'
import {
  composeUpRoachNetServices,
  detectRoachNetContainerRuntime,
  DOCKER_DOCS,
  getRoachNetComposeProjectName,
  startRoachNetContainerRuntime,
} from './lib/roachnet_container_runtime.mjs'
import { getRoachNetLocalHostname } from './lib/roachtail_hostname.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const uiRoot = path.join(repoRoot, 'setup-ui')

const DEFAULT_SOURCE_REPO_URL = 'https://github.com/AHGRoach/RoachNet.git'
const DEFAULT_SOURCE_REF = 'main'
const TASK_LOG_LIMIT = 800
const SERVER_HOST = '127.0.0.1'
const DOCKER_BOOT_TIMEOUT_MS = 180_000
const PORT_WAIT_INTERVAL_MS = 1_500
const PORT_WAIT_TIMEOUT_MS = 180_000
const INSTALLER_DIAGNOSTICS_CACHE_TTL_MS = 30_000
const INSTALLER_DIAGNOSTIC_COMMAND_TIMEOUT_MS = 1_500
const GITHUB_API_ROOT = 'https://api.github.com'
const DEFAULT_ROACHCLAW_MODEL = 'qwen2.5-coder:1.5b'
const OLLAMA_RELEASE_API_URL = 'https://api.github.com/repos/ollama/ollama/releases/latest'
const OLLAMA_DIRECT_DOWNLOAD_URL =
  process.env.ROACHNET_BUNDLED_OLLAMA_URL?.trim() || 'https://ollama.com/download/ollama-darwin.tgz'
const OLLAMA_FALLBACK_VERSION =
  process.env.ROACHNET_BUNDLED_OLLAMA_VERSION?.trim() || 'contained'
const GIB = 1024 ** 3
const MIN_FREE_BYTES_BASE_INSTALL = 2 * GIB
const MIN_FREE_BYTES_WITH_ROACHCLAW = 5 * GIB

const runtimeState = {
  task: null,
  lastCompletedTask: null,
  persistedConfig: null,
  diagnosticsCache: {
    value: null,
    expiresAt: 0,
    refreshPromise: null,
  },
}

function getSharedAppDataDir() {
  if (process.env.ROACHNET_SHARED_APP_DATA_DIR) {
    return path.resolve(process.env.ROACHNET_SHARED_APP_DATA_DIR)
  }

  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', 'roachnet')
  }

  if (process.platform === 'win32') {
    return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'RoachNet')
  }

  return path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'roachnet')
}

function getInstallerConfigPath() {
  return (
    process.env.ROACHNET_INSTALLER_CONFIG_PATH ||
    path.join(getSharedAppDataDir(), 'roachnet-installer.json')
  )
}

function getLegacyInstallerConfigPath() {
  return path.join(os.homedir(), '.roachnet-setup.json')
}

function writeSetupReadyFile(url) {
  const readyFilePath = process.env.ROACHNET_SETUP_READY_FILE
  if (!readyFilePath) {
    return
  }

  mkdirSync(path.dirname(readyFilePath), { recursive: true })
  writeFileSync(
    readyFilePath,
    JSON.stringify(
      {
        url,
        pid: process.pid,
        startedAt: new Date().toISOString(),
      },
      null,
      2
    ) + '\n',
    'utf8'
  )
}

function hashString(value) {
  return createHash('sha256').update(value).digest('hex')
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

function formatUrlHost(host) {
  const trimmed = String(host || '').trim()
  if (!trimmed) {
    return '127.0.0.1'
  }

  return trimmed.includes(':') && !trimmed.startsWith('[') ? `[${trimmed}]` : trimmed
}

function normalizeHostName(host) {
  return String(host || '')
    .trim()
    .replace(/^\[|\]$/g, '')
    .toLowerCase()
}

function isLoopbackHost(host) {
  const normalizedHost = normalizeHostName(host)
  return ['localhost', '127.0.0.1', '::1', '0.0.0.0', '::'].includes(normalizedHost)
}

function resolveInstallBaseUrl(existingUrl, host, port) {
  const normalizedHost = normalizeHostName(host) || '127.0.0.1'
  const fallbackUrl = `http://${formatUrlHost(normalizedHost)}:${port}`
  const trimmedExistingUrl = String(existingUrl || '').trim()

  if (!trimmedExistingUrl) {
    return fallbackUrl
  }

  try {
    const parsedUrl = new URL(trimmedExistingUrl)
    if (isLoopbackHost(parsedUrl.hostname) || normalizeHostName(parsedUrl.hostname) === normalizedHost) {
      parsedUrl.hostname = normalizedHost
      parsedUrl.port = String(port)
      parsedUrl.pathname = '/'
      parsedUrl.search = ''
      parsedUrl.hash = ''
      return parsedUrl.toString().replace(/\/$/, '')
    }

    return parsedUrl.toString().replace(/\/$/, '')
  } catch {
    return fallbackUrl
  }
}

function readJsonFile(filePath) {
  if (!existsSync(filePath)) {
    return null
  }

  try {
    return JSON.parse(readFileSync(filePath, 'utf8'))
  } catch {
    return null
  }
}

function saveInstallerConfig(config) {
  const configPath = getInstallerConfigPath()
  mkdirSync(path.dirname(configPath), { recursive: true })
  runtimeState.persistedConfig = config
  writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n', 'utf8')

  const legacyConfigPath = getLegacyInstallerConfigPath()
  if (legacyConfigPath !== configPath) {
    writeFileSync(legacyConfigPath, JSON.stringify(config, null, 2) + '\n', 'utf8')
  }
}

function invalidateInstallerDiagnosticsCache() {
  runtimeState.diagnosticsCache = {
    value: null,
    expiresAt: 0,
    refreshPromise: null,
  }
}

function stripUndefinedEntries(input) {
  return Object.fromEntries(Object.entries(input).filter(([, value]) => value !== undefined))
}

function shouldPreserveTransientInstallerPaths() {
  const explicitConfigPath = process.env.ROACHNET_INSTALLER_CONFIG_PATH?.trim()
  return explicitConfigPath?.length > 0 || process.env.ROACHNET_ALLOW_TRANSIENT_INSTALL_PATHS === '1'
}

function isTransientRoachNetPath(candidatePath) {
  if (typeof candidatePath !== 'string' || !candidatePath.trim()) {
    return false
  }

  const normalizedPath = normalizeInputPath(candidatePath).toLowerCase()
  const tmpRoots = [
    normalizeInputPath(os.tmpdir()),
    '/tmp',
    '/private/tmp',
    '/var/folders',
    '/private/var/folders',
  ].map((value) => value.toLowerCase())

  return tmpRoots.some((root) => normalizedPath.startsWith(root)) && normalizedPath.includes('roachnet')
}

function sanitizePersistedInstallerConfig(config) {
  if (!config || typeof config !== 'object' || shouldPreserveTransientInstallerPaths()) {
    return config || {}
  }

  const defaultInstallPath = normalizeInputPath(getDefaultInstallPath())
  const installPath = normalizeInputPath(config.installPath || defaultInstallPath)
  const installPathWasTransient = isTransientRoachNetPath(installPath)
  const sanitizedInstallPath = installPathWasTransient ? defaultInstallPath : installPath
  const sanitizedInstalledAppPath = installPathWasTransient
    ? getCanonicalInstalledAppPath(sanitizedInstallPath)
    : normalizeInputPath(config.installedAppPath || getCanonicalInstalledAppPath(sanitizedInstallPath))
  const sanitizedStoragePath = installPathWasTransient
    ? normalizeInputPath(path.join(sanitizedInstallPath, 'storage'))
    : normalizeInputPath(config.storagePath || path.join(sanitizedInstallPath, 'storage'))

  const normalizedAppPath =
    isTransientRoachNetPath(sanitizedInstalledAppPath) ||
    !sanitizedInstalledAppPath.startsWith(`${sanitizedInstallPath}${path.sep}`)
      ? getCanonicalInstalledAppPath(sanitizedInstallPath)
      : sanitizedInstalledAppPath
  const normalizedStoragePath =
    isTransientRoachNetPath(sanitizedStoragePath) ||
    !sanitizedStoragePath.startsWith(`${sanitizedInstallPath}${path.sep}`)
      ? normalizeInputPath(path.join(sanitizedInstallPath, 'storage'))
      : sanitizedStoragePath

  const nextConfig = {
    ...config,
    installPath: sanitizedInstallPath,
    installedAppPath: normalizedAppPath,
    storagePath: normalizedStoragePath,
  }

  if (installPathWasTransient) {
    nextConfig.setupCompletedAt = null
    nextConfig.pendingLaunchIntro = false
    nextConfig.pendingRoachClawSetup = false
    nextConfig.bootstrapPending = false
    nextConfig.bootstrapFailureCount = 0
    nextConfig.lastRuntimeHealthAt = null
  }

  return nextConfig
}

function loadPersistedInstallerConfig() {
  if (runtimeState.persistedConfig) {
    return runtimeState.persistedConfig
  }

  const configPath = getInstallerConfigPath()
  const legacyConfigPath = getLegacyInstallerConfigPath()
  const usingExplicitConfigPath = Boolean(process.env.ROACHNET_INSTALLER_CONFIG_PATH)
  const primaryConfig = readJsonFile(configPath)
  const legacyConfig =
    usingExplicitConfigPath || configPath === legacyConfigPath ? null : readJsonFile(legacyConfigPath)

  const persistedConfig = primaryConfig || legacyConfig || {}
  runtimeState.persistedConfig = sanitizePersistedInstallerConfig(persistedConfig)

  if (!usingExplicitConfigPath && !primaryConfig && legacyConfig) {
    mkdirSync(path.dirname(configPath), { recursive: true })
    writeFileSync(configPath, JSON.stringify(runtimeState.persistedConfig, null, 2) + '\n', 'utf8')
  }

  if (
    !usingExplicitConfigPath &&
    JSON.stringify(runtimeState.persistedConfig) !== JSON.stringify(persistedConfig)
  ) {
    mkdirSync(path.dirname(configPath), { recursive: true })
    writeFileSync(configPath, JSON.stringify(runtimeState.persistedConfig, null, 2) + '\n', 'utf8')
  }

  return runtimeState.persistedConfig
}

function getDefaultInstallPath() {
  return path.join(os.homedir(), 'RoachNet')
}

function getDefaultInstalledAppPath(baseInstallPath = getDefaultInstallPath()) {
  if (process.platform === 'darwin') {
    return path.join(baseInstallPath, 'app', 'RoachNet.app')
  }

  if (process.platform === 'win32') {
    return path.join(baseInstallPath, 'app', 'RoachNet', 'RoachNet.exe')
  }

  return path.join(baseInstallPath, 'app', 'RoachNet.AppImage')
}

function getCurrentAppVersion() {
  const packagedVersion = process.env.ROACHNET_APP_VERSION?.trim()
  if (packagedVersion) {
    return packagedVersion
  }

  return readJsonFile(path.join(repoRoot, 'package.json'))?.version || '1.0.0'
}

function parseGitHubRepo(sourceRepoUrl = DEFAULT_SOURCE_REPO_URL) {
  const match = String(sourceRepoUrl)
    .trim()
    .match(/github\.com[:/](?<owner>[^/]+)\/(?<repo>[^/.]+?)(?:\.git)?$/i)

  if (!match?.groups?.owner || !match?.groups?.repo) {
    return null
  }

  return {
    owner: match.groups.owner,
    repo: match.groups.repo,
  }
}

function resolvePackagedSetupBundlePath() {
  const explicitBundlePath = process.env.ROACHNET_SETUP_APP_BUNDLE?.trim()
  if (explicitBundlePath) {
    const normalizedExplicitPath = normalizeInputPath(explicitBundlePath)
    if (normalizedExplicitPath.endsWith('.app')) {
      return normalizedExplicitPath
    }

    const markerBasename = path.basename(normalizedExplicitPath)
    if (markerBasename === 'setup-assets.marker') {
      return path.dirname(path.dirname(path.dirname(path.dirname(normalizedExplicitPath))))
    }

    if (path.basename(normalizedExplicitPath) === 'InstallerAssets') {
      return path.dirname(path.dirname(path.dirname(normalizedExplicitPath)))
    }

    if (normalizedExplicitPath.includes(`${path.sep}Contents${path.sep}Resources${path.sep}`)) {
      return path.dirname(path.dirname(path.dirname(normalizedExplicitPath)))
    }

    return normalizedExplicitPath
  }

  if (process.platform !== 'darwin') {
    return null
  }

  const resourcesPath = path.dirname(repoRoot)
  const contentsPath = path.dirname(resourcesPath)
  const bundlePath = path.dirname(contentsPath)

  if (bundlePath.endsWith('.app') && path.basename(contentsPath) === 'Contents') {
    return bundlePath
  }

  return null
}

function resolvePackagedInstallerAssetsPath() {
  const explicitBundlePath = process.env.ROACHNET_SETUP_APP_BUNDLE?.trim()
  if (explicitBundlePath) {
    const normalizedExplicitPath = normalizeInputPath(explicitBundlePath)
    if (path.basename(normalizedExplicitPath) === 'setup-assets.marker') {
      return path.dirname(normalizedExplicitPath)
    }

    if (path.basename(normalizedExplicitPath) === 'InstallerAssets') {
      return normalizedExplicitPath
    }

    if (normalizedExplicitPath.endsWith('.app')) {
      return path.join(normalizedExplicitPath, 'Contents', 'Resources', 'InstallerAssets')
    }

    if (normalizedExplicitPath.includes(`${path.sep}Contents${path.sep}Resources${path.sep}`)) {
      return path.join(path.dirname(normalizedExplicitPath), 'InstallerAssets')
    }
  }

  const setupBundlePath = resolvePackagedSetupBundlePath()
  if (!setupBundlePath) {
    return null
  }

  return path.join(setupBundlePath, 'Contents', 'Resources', 'InstallerAssets')
}

function getBundledInstallerAssetPath(...pathSegments) {
  const installerAssetsPath = resolvePackagedInstallerAssetsPath()
  if (!installerAssetsPath) {
    return null
  }

  return path.join(installerAssetsPath, ...pathSegments)
}

function getLocalArtifactDescriptor(version = getCurrentAppVersion()) {
  const arch = process.arch
  const setupBundlePath = resolvePackagedSetupBundlePath()
  const setupBundleDir = setupBundlePath ? path.dirname(setupBundlePath) : null
  const setupResourcesDir = setupBundlePath ? path.join(setupBundlePath, 'Contents', 'Resources') : null
  const persistedInstallPath = normalizeInputPath(
    loadPersistedInstallerConfig().installPath || getDefaultInstallPath()
  )
  const canonicalTargetPath = getCanonicalInstalledAppPath(persistedInstallPath)

  if (process.platform === 'darwin') {
    return {
      targetPath: canonicalTargetPath,
      kind: 'bundle',
      bundleName: 'RoachNet.app',
      archiveNames: [`RoachNet-${version}-mac-${arch}.zip`],
      localCandidates: [
        path.join(repoRoot, 'desktop-dist', `mac-${arch}`, 'RoachNet.app'),
        path.join(repoRoot, 'native', 'macos', 'dist', 'RoachNet.app'),
        setupBundleDir ? path.join(setupBundleDir, 'RoachNet.app') : null,
        setupResourcesDir ? path.join(setupResourcesDir, 'InstallerAssets', 'RoachNet.app') : null,
        path.join(repoRoot, 'desktop-dist', `RoachNet-${version}-mac-${arch}.zip`),
        path.join(repoRoot, 'native', 'macos', 'dist', `RoachNet-${version}-mac-${arch}.zip`),
        setupBundleDir ? path.join(setupBundleDir, `RoachNet-${version}-mac-${arch}.zip`) : null,
        setupResourcesDir ? path.join(setupResourcesDir, 'InstallerAssets', `RoachNet-${version}-mac-${arch}.zip`) : null,
      ].filter(Boolean),
      assetMatcher(name) {
        if (typeof name !== 'string') {
          return false
        }
        return (
          name === `RoachNet-${version}-mac-${arch}.zip` ||
          (name.includes(`mac-${arch}`) && name.endsWith('.zip'))
        )
      },
    }
  }

  if (process.platform === 'win32') {
    return {
      targetPath: canonicalTargetPath,
      kind: 'binary',
      bundleName: 'RoachNet.exe',
      archiveNames: [`RoachNet-${version}-win-${arch}.exe`],
      localCandidates: [
        path.join(repoRoot, 'desktop-dist', `RoachNet-${version}-win-${arch}.exe`),
        setupBundleDir ? path.join(setupBundleDir, `RoachNet-${version}-win-${arch}.exe`) : null,
      ].filter(Boolean),
      assetMatcher(name) {
        if (typeof name !== 'string') {
          return false
        }
        return name.includes(`win-${arch}`) && name.endsWith('.exe')
      },
    }
  }

  return {
    targetPath: canonicalTargetPath,
    kind: 'binary',
    bundleName: 'RoachNet.AppImage',
    archiveNames: [`RoachNet-${version}-linux-${arch}.AppImage`],
    localCandidates: [
      path.join(repoRoot, 'desktop-dist', `RoachNet-${version}-linux-${arch}.AppImage`),
      setupBundleDir ? path.join(setupBundleDir, `RoachNet-${version}-linux-${arch}.AppImage`) : null,
    ].filter(Boolean),
    assetMatcher(name) {
      if (typeof name !== 'string') {
        return false
      }
      return name.includes(`linux-${arch}`) && name.endsWith('.AppImage')
    },
  }
}

async function fetchJson(url, options = {}) {
  const token = process.env.GITHUB_TOKEN?.trim() || process.env.GH_TOKEN?.trim() || ''
  const response = await fetch(url, {
    headers: {
      Accept: 'application/vnd.github+json, application/json',
      'User-Agent': 'RoachNet-Setup',
      ...(token && url.startsWith('https://api.github.com/')
        ? { Authorization: `Bearer ${token}` }
        : {}),
      ...(options.headers || {}),
    },
  })

  if (!response.ok) {
    throw new Error(`Request failed for ${url}: ${response.status} ${response.statusText}`)
  }

  return response.json()
}

async function downloadFile(url, destinationPath) {
  const response = await fetch(url, {
    headers: {
      Accept: 'application/octet-stream, application/zip, application/json',
      'User-Agent': 'RoachNet-Setup',
    },
    redirect: 'follow',
  })

  if (!response.ok || !response.body) {
    throw new Error(`Download failed for ${url}: ${response.status} ${response.statusText}`)
  }

  await ensureDirectory(path.dirname(destinationPath))
  await pipeline(Readable.fromWeb(response.body), createWriteStream(destinationPath))
  return destinationPath
}

async function findFirstPathNamed(rootPath, targetName) {
  if (!existsSync(rootPath)) {
    return null
  }

  const entries = await readdir(rootPath, { withFileTypes: true })
  for (const entry of entries) {
    const fullPath = path.join(rootPath, entry.name)
    if (entry.name === targetName) {
      return fullPath
    }

    if (entry.isDirectory()) {
      const nested = await findFirstPathNamed(fullPath, targetName)
      if (nested) {
        return nested
      }
    }
  }

  return null
}

async function extractArchive(archivePath, destinationPath) {
  await ensureDirectory(destinationPath)

  if (process.platform === 'darwin') {
    await runProcess('ditto', ['-x', '-k', archivePath, destinationPath], {
      env: getShellEnv(),
    })
    return
  }

  if (process.platform === 'win32') {
    await runProcess(
      'powershell',
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        `Expand-Archive -LiteralPath '${archivePath.replace(/'/g, "''")}' -DestinationPath '${destinationPath.replace(/'/g, "''")}' -Force`,
      ],
      {
        env: getShellEnv(),
      }
    )
    return
  }

  await runProcess('unzip', ['-o', archivePath, '-d', destinationPath], {
    env: getShellEnv(),
  })
}

async function installDirectoryArtifact(sourcePath, targetPath) {
  await rm(targetPath, { recursive: true, force: true }).catch(() => {})
  await ensureDirectory(path.dirname(targetPath))
  if (process.platform === 'darwin') {
    try {
      await runProcess('ditto', ['--clone', '--noqtn', sourcePath, targetPath], {
        env: getShellEnv(),
      })
    } catch (cloneError) {
      await runProcess('ditto', ['--noqtn', sourcePath, targetPath], {
        env: getShellEnv(),
      }).catch((fallbackError) => {
        throw new Error(
          [
            `Failed to install directory artifact from ${sourcePath} to ${targetPath}.`,
            `clone attempt: ${cloneError?.message || cloneError}`,
            `fallback attempt: ${fallbackError?.message || fallbackError}`,
          ].join('\n\n')
        )
      })
    }
  } else {
    await cp(sourcePath, targetPath, {
      recursive: true,
      force: true,
    })
  }
  await clearMacQuarantine(targetPath)
}

function installedAppCandidates(targetPath) {
  const normalizedTargetPath = normalizeInputPath(targetPath)
  const bundleName = path.basename(normalizedTargetPath)
  return [...new Set([
    normalizedTargetPath,
    normalizeInputPath(path.join(os.homedir(), 'Applications', bundleName)),
    normalizeInputPath(path.join('/Applications', bundleName)),
  ])]
}

async function terminateRunningRoachNetApps(task) {
  if (process.platform !== 'darwin') {
    return
  }

  try {
    await runProcess('pkill', ['-f', '/RoachNet.app/Contents/MacOS/RoachNetApp'], {
      env: getShellEnv(),
      timeoutMs: 5_000,
    })
    appendTaskLog(task, 'Closed running RoachNet app instances before replacing the installed copy.')
  } catch (error) {
    const detail = String(error?.message || error)
    if (!detail.includes('exit code 1')) {
      appendTaskLog(task, `Could not close all running RoachNet instances cleanly: ${detail}`)
    }
  }
}

async function removeStaleInstalledAppCopies(targetPath, task) {
  const normalizedTargetPath = normalizeInputPath(targetPath)

  for (const candidatePath of installedAppCandidates(normalizedTargetPath)) {
    if (candidatePath === normalizedTargetPath || !existsSync(candidatePath)) {
      continue
    }

    await rm(candidatePath, { recursive: true, force: true }).catch(() => {})
    appendTaskLog(task, `Removed stale RoachNet app copy at ${candidatePath}.`)
  }
}

async function installFileArtifact(sourcePath, targetPath) {
  await ensureDirectory(path.dirname(targetPath))
  await rm(targetPath, { force: true }).catch(() => {})
  await copyFile(sourcePath, targetPath)
  if (process.platform !== 'win32') {
    await chmod(targetPath, 0o755).catch(() => {})
  }
  await clearMacQuarantine(targetPath)
}

async function clearMacQuarantine(targetPath) {
  if (process.platform !== 'darwin') {
    return
  }

  if (!existsSync(targetPath)) {
    return
  }

  await runProcess('xattr', ['-d', 'com.apple.quarantine', targetPath], {
    env: getShellEnv(),
    timeoutMs: 15_000,
  }).catch(() => {})

  await runProcess('xattr', ['-d', 'com.apple.provenance', targetPath], {
    env: getShellEnv(),
    timeoutMs: 15_000,
  }).catch(() => {})

  const embeddedRuntimePath = path.join(targetPath, 'Contents', 'Resources', 'EmbeddedRuntime')
  const isAppBundle = targetPath.endsWith('.app')

  if (isAppBundle) {
    // Unsigned installs need the copied app bundle itself normalized as the
    // actual launch boundary, not only the embedded Node subtree.
    await runProcess('xattr', ['-cr', targetPath], {
      env: getShellEnv(),
      timeoutMs: 300_000,
    }).catch(() => {})

    await runProcess('codesign', ['--force', '--deep', '--sign', '-', targetPath], {
      env: getShellEnv(),
      timeoutMs: 300_000,
    }).catch(() => {})
    return
  }

  if (existsSync(embeddedRuntimePath)) {
    await runProcess('xattr', ['-cr', embeddedRuntimePath], {
      env: getShellEnv(),
      timeoutMs: 20_000,
    }).catch(() => {})
  }
}

async function resolveLocalNativeAppSource(config, task) {
  const descriptor = getLocalArtifactDescriptor(getCurrentAppVersion())

  for (const candidatePath of descriptor.localCandidates) {
    if (!existsSync(candidatePath)) {
      continue
    }

    appendTaskLog(task, `Using local desktop app artifact from ${candidatePath}.`)

    if (descriptor.kind === 'bundle' && candidatePath.endsWith('.app')) {
      return {
        type: 'bundle',
        path: candidatePath,
        targetPath: normalizeInputPath(config.installedAppPath || descriptor.targetPath),
      }
    }

    return {
      type: 'archive',
      path: candidatePath,
      targetPath: normalizeInputPath(config.installedAppPath || descriptor.targetPath),
      bundleName: descriptor.bundleName,
    }
  }

  return null
}

async function resolveReleaseNativeAppSource(config, task) {
  const descriptor = getLocalArtifactDescriptor(getCurrentAppVersion())
  const repo = parseGitHubRepo(config.sourceRepoUrl)
  if (!repo) {
    throw new Error('RoachNet Setup can only auto-download packaged desktop apps from GitHub repositories right now.')
  }

  appendTaskLog(task, `Checking GitHub releases for ${repo.owner}/${repo.repo} desktop artifacts...`)

  const releasePayload =
    config.releaseChannel === 'stable'
      ? await fetchJson(`${GITHUB_API_ROOT}/repos/${repo.owner}/${repo.repo}/releases/latest`)
      : await fetchJson(`${GITHUB_API_ROOT}/repos/${repo.owner}/${repo.repo}/releases`)

  const release =
    config.releaseChannel === 'stable'
      ? releasePayload
      : releasePayload.find((entry) => !entry.draft && Boolean(entry.prerelease)) ||
        releasePayload.find((entry) => !entry.draft)

  if (!release?.assets?.length) {
    throw new Error('No downloadable desktop app assets were found in the selected release channel.')
  }

  const asset = release.assets.find((entry) => descriptor.assetMatcher(entry.name))
  if (!asset?.browser_download_url) {
    throw new Error('No matching packaged desktop app asset was found for this platform and architecture.')
  }

  appendTaskLog(task, `Downloading ${asset.name} from GitHub releases...`)
  const downloadDirectory = await createSetupTempDirectory(config, 'roachnet-app-download')
  const downloadedPath = path.join(downloadDirectory, asset.name)
  await downloadFile(asset.browser_download_url, downloadedPath)

  return {
    type: descriptor.kind === 'bundle' ? 'archive' : 'binary',
    path: downloadedPath,
    targetPath: normalizeInputPath(config.installedAppPath || descriptor.targetPath),
    bundleName: descriptor.bundleName,
  }
}

async function installNativeDesktopApp(config, task) {
  const descriptor = getLocalArtifactDescriptor(getCurrentAppVersion())
  const targetPath = normalizeInputPath(config.installedAppPath || descriptor.targetPath)
  const source =
    (await resolveLocalNativeAppSource({ ...config, installedAppPath: targetPath }, task)) ||
    (await resolveReleaseNativeAppSource({ ...config, installedAppPath: targetPath }, task))

  await terminateRunningRoachNetApps(task)
  await removeStaleInstalledAppCopies(targetPath, task)
  appendTaskLog(task, `Installing the native RoachNet desktop app at ${targetPath}...`)

  if (source.type === 'bundle') {
    await installDirectoryArtifact(source.path, targetPath)
    return {
      installedAppPath: targetPath,
      sourcePath: source.path,
      sourceType: 'bundle',
    }
  }

  if (descriptor.kind === 'bundle') {
    const extractionRoot = await createSetupTempDirectory(config, 'roachnet-app-extract')
    await extractArchive(source.path, extractionRoot)
    const extractedBundlePath = await findFirstPathNamed(extractionRoot, source.bundleName)

    if (!extractedBundlePath) {
      throw new Error(`The downloaded RoachNet desktop archive did not contain ${source.bundleName}.`)
    }

    await installDirectoryArtifact(extractedBundlePath, targetPath)
    return {
      installedAppPath: targetPath,
      sourcePath: source.path,
      sourceType: 'archive',
    }
  }

  await installFileArtifact(source.path, targetPath)
  return {
    installedAppPath: targetPath,
    sourcePath: source.path,
    sourceType: source.type,
  }
}

async function launchNativeDesktopApp(appPath) {
  if (!appPath) {
    throw new Error('No native RoachNet app path is configured yet.')
  }

  if (process.platform === 'darwin') {
    spawn('open', [appPath], { detached: true, stdio: 'ignore' }).unref()
    return
  }

  if (process.platform === 'win32') {
    spawn('cmd', ['/c', 'start', '', appPath], { detached: true, stdio: 'ignore' }).unref()
    return
  }

  spawn(appPath, [], { detached: true, stdio: 'ignore' }).unref()
}

async function requestSetupAppQuit() {
  if (process.platform !== 'darwin') {
    return
  }

  const quitScript = `
tell application "RoachNet Setup"
  quit
end tell
`.trim()

  await runProcess('osascript', ['-e', quitScript], {
    env: getShellEnv(),
    timeoutMs: 10_000,
  }).catch(() => {})
}

function hasCurrentWorkspaceSource() {
  return (
    existsSync(path.join(repoRoot, 'package.json')) &&
    existsSync(path.join(repoRoot, 'admin')) &&
    existsSync(path.join(repoRoot, 'scripts', 'run-roachnet.mjs'))
  )
}

function normalizeInputPath(inputPath) {
  if (!inputPath) {
    return getDefaultInstallPath()
  }

  if (inputPath.startsWith('~/')) {
    return path.join(os.homedir(), inputPath.slice(2))
  }

  return path.resolve(inputPath)
}

function getSetupWorkspaceRoot(config = {}) {
  const explicitRoot = process.env.ROACHNET_SETUP_WORK_ROOT?.trim()
  if (explicitRoot) {
    return normalizeInputPath(explicitRoot)
  }

  const installPath = normalizeInputPath(
    config.installPath || loadPersistedInstallerConfig().installPath || getDefaultInstallPath()
  )

  return normalizeInputPath(path.join(installPath, '.roachnet-setup'))
}

async function createSetupTempDirectory(config, prefix) {
  const tempRoot = path.join(getSetupWorkspaceRoot(config), 'tmp')
  await ensureDirectory(tempRoot)
  return mkdtemp(path.join(tempRoot, `${prefix}-`))
}

function getCanonicalInstalledAppPath(installPath) {
  return normalizeInputPath(getDefaultInstalledAppPath(normalizeInputPath(installPath)))
}

function remapPathWithinInstallRoot(targetPath, fromInstallRoot, toInstallRoot) {
  const normalizedTargetPath = normalizeInputPath(targetPath)
  const normalizedFromRoot = normalizeInputPath(fromInstallRoot)
  const normalizedToRoot = normalizeInputPath(toInstallRoot)

  if (normalizedTargetPath === normalizedFromRoot) {
    return normalizedToRoot
  }

  const fromPrefix = `${normalizedFromRoot}${path.sep}`
  if (normalizedTargetPath.startsWith(fromPrefix)) {
    return path.join(normalizedToRoot, normalizedTargetPath.slice(fromPrefix.length))
  }

  return normalizedTargetPath
}

async function movePath(sourcePath, destinationPath) {
  await ensureDirectory(path.dirname(destinationPath))

  try {
    await rename(sourcePath, destinationPath)
  } catch (error) {
    if (error?.code !== 'EXDEV') {
      throw error
    }

    await cp(sourcePath, destinationPath, { recursive: true, force: true })
    await rm(sourcePath, { recursive: true, force: true })
  }
}

async function pathExists(targetPath) {
  try {
    await stat(targetPath)
    return true
  } catch {
    return false
  }
}

async function finalizeInstallRoot(stagingInstallPath, finalInstallPath, task) {
  const existingInstallPresent = await pathExists(finalInstallPath)
  const backupInstallPath = existingInstallPresent
    ? path.join(
        path.dirname(finalInstallPath),
        `${path.basename(finalInstallPath)}.backup-${Date.now()}`
      )
    : null

  if (backupInstallPath) {
    appendTaskLog(task, `Moving the previous RoachNet install aside to ${backupInstallPath}...`)
    await movePath(finalInstallPath, backupInstallPath)
  }

  try {
    appendTaskLog(task, `Moving the staged install into ${finalInstallPath}...`)
    await movePath(stagingInstallPath, finalInstallPath)

    if (backupInstallPath) {
      await rm(backupInstallPath, { recursive: true, force: true })
    }
  } catch (error) {
    if (!(await pathExists(finalInstallPath)) && backupInstallPath && (await pathExists(backupInstallPath))) {
      await movePath(backupInstallPath, finalInstallPath)
    }

    throw error
  }
}

function toComposePath(value) {
  return value.replace(/\\/g, '/')
}

function randomSecret(size = 24) {
  return randomBytes(size).toString('hex')
}

function mimeTypeFor(filePath) {
  const extension = path.extname(filePath).toLowerCase()

  switch (extension) {
    case '.css':
      return 'text/css; charset=utf-8'
    case '.js':
      return 'application/javascript; charset=utf-8'
    case '.json':
      return 'application/json; charset=utf-8'
    case '.svg':
      return 'image/svg+xml'
    case '.png':
      return 'image/png'
    case '.ico':
      return 'image/x-icon'
    default:
      return 'text/html; charset=utf-8'
  }
}

function sendJson(response, payload, statusCode = 200) {
  response.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  })
  response.end(JSON.stringify(payload))
}

function sendText(response, payload, statusCode = 200) {
  response.writeHead(statusCode, {
    'Content-Type': 'text/plain; charset=utf-8',
    'Cache-Control': 'no-store',
  })
  response.end(payload)
}

async function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    let buffer = ''

    request.setEncoding('utf8')
    request.on('data', (chunk) => {
      buffer += chunk
    })
    request.on('end', () => {
      resolve(buffer)
    })
    request.on('error', reject)
  })
}

async function parseJsonBody(request) {
  const raw = await readRequestBody(request)

  if (!raw) {
    return {}
  }

  return JSON.parse(raw)
}

async function serveStaticFile(response, filePath) {
  if (!existsSync(filePath)) {
    sendText(response, 'Not found', 404)
    return
  }

  const fileStats = await stat(filePath)
  response.writeHead(200, {
    'Content-Type': mimeTypeFor(filePath),
    'Content-Length': String(fileStats.size),
    'Cache-Control': 'no-store',
  })
  createReadStream(filePath).pipe(response)
}

async function runProcess(binary, args = [], options = {}) {
  const {
    cwd = repoRoot,
    env = process.env,
    shell = false,
    onStdout,
    onStderr,
    timeoutMs = 0,
  } = options

  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      cwd,
      env,
      shell,
      detached: process.platform !== 'win32',
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    let stdout = ''
    let stderr = ''
    let timedOut = false
    const timeoutHandle =
      timeoutMs > 0
        ? setTimeout(() => {
            timedOut = true
            if (process.platform !== 'win32' && child.pid) {
              try {
                process.kill(-child.pid, 'SIGKILL')
              } catch {}
            }
            child.kill('SIGKILL')
          }, timeoutMs)
        : null

    child.stdout.on('data', (chunk) => {
      const text = chunk.toString()
      stdout += text
      onStdout?.(text)
    })

    child.stderr.on('data', (chunk) => {
      const text = chunk.toString()
      stderr += text
      onStderr?.(text)
    })

    child.on('error', reject)
    child.on('close', (code) => {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }

      if (timedOut) {
        reject(
          new Error(
            `${binary}${args.length ? ` ${args.join(' ')}` : ''} timed out after ${timeoutMs}ms\n${
              stderr.trim() || stdout.trim()
            }`
          )
        )
        return
      }

      if (code === 0) {
        resolve({ code, stdout, stderr })
        return
      }

      reject(
        new Error(
          `${binary}${args.length ? ` ${args.join(' ')}` : ''} exited with code ${code}\n${
            stderr.trim() || stdout.trim()
          }`
        )
      )
    })
  })
}

async function runShell(command, options = {}) {
  return runProcess(command, [], {
    ...options,
    shell: true,
  })
}

async function provisionRoachTailLocalHostname(task) {
  if (process.platform !== 'darwin') {
    return
  }

  const hostname = getRoachNetLocalHostname(process.env)
  const hostsFile = process.env.ROACHNET_HOSTS_FILE?.trim() || '/etc/hosts'
  const aliasInstallerPath = path.join(repoRoot, 'scripts', 'install-roachtail-hostname.mjs')
  const aliasInstallerArgs = ['--apply']

  if (hostsFile === '/etc/hosts') {
    aliasInstallerArgs.push('--interactive')
  }

  try {
    appendTaskLog(task, `Provisioning the RoachTail local alias ${hostname} via ${hostsFile}...`)
    await runProcess(process.execPath, [aliasInstallerPath, ...aliasInstallerArgs], {
      env: {
        ...getShellEnv(),
        ROACHNET_LOCAL_HOSTNAME: hostname,
        ROACHNET_HOSTS_FILE: hostsFile,
      },
      timeoutMs: 20_000,
    })

    appendTaskLog(task, `RoachTail local alias ${hostname} now points at the contained desktop lane.`)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    appendTaskLog(task, `RoachTail local alias could not be provisioned automatically. ${message}`)

    if (process.env.ROACHNET_REQUIRE_LOCAL_ALIAS === '1') {
      throw error
    }
  }
}

async function commandPath(command) {
  const localCandidate = getLocalToolBinaryPath(command.replace(/\.cmd$/i, ''), repoRoot)
  if (existsSync(localCandidate)) {
    return localCandidate
  }

  try {
    const binary = process.platform === 'win32' ? 'where' : 'which'
    const result = await runProcess(binary, [command], {
      env: getShellEnv(),
      timeoutMs: 1_500,
    })
    return result.stdout.split(/\r?\n/).find(Boolean)?.trim() || null
  } catch {
    return null
  }
}

async function commandExists(command, args = ['--version']) {
  return Boolean(await commandPath(command))
}

async function commandResponds(command, args = ['--version']) {
  try {
    await runProcess(command, args, {
      env: getShellEnv(),
      timeoutMs: INSTALLER_DIAGNOSTIC_COMMAND_TIMEOUT_MS,
    })
    return true
  } catch {
    return false
  }
}

async function detectPackageManager() {
  if (process.platform === 'darwin') {
    return {
      id: (await commandExists('brew')) ? 'brew' : 'none',
      label: (await commandExists('brew')) ? 'Homebrew' : 'None detected',
    }
  }

  if (process.platform === 'win32') {
    if (await commandExists('winget', ['--version'])) {
      return { id: 'winget', label: 'WinGet' }
    }

    if (await commandExists('choco', ['--version'])) {
      return { id: 'choco', label: 'Chocolatey' }
    }

    return { id: 'none', label: 'None detected' }
  }

  const candidates = [
    ['apt-get', 'apt'],
    ['dnf', 'dnf'],
    ['yum', 'yum'],
    ['pacman', 'pacman'],
    ['zypper', 'zypper'],
  ]

  for (const [command, id] of candidates) {
    if (await commandExists(command, ['--version'])) {
      return { id, label: command }
    }
  }

  return { id: 'none', label: 'None detected' }
}

function getDependencyPackageTargets(packageManagerId) {
  const targets = {
    brew: {
      git: ['git'],
      node: ['node@22'],
      npm: ['node@22'],
      docker: ['docker'],
      dockerCompose: ['docker'],
      ollama: ['ollama'],
    },
    winget: {
      git: ['Git.Git'],
      node: ['OpenJS.NodeJS.LTS'],
      npm: ['OpenJS.NodeJS.LTS'],
      docker: ['Docker.DockerDesktop'],
      dockerCompose: ['Docker.DockerDesktop'],
      ollama: ['Ollama.Ollama'],
    },
    choco: {
      git: ['git'],
      node: ['nodejs-lts'],
      npm: ['nodejs-lts'],
      docker: ['docker-desktop'],
      dockerCompose: ['docker-desktop'],
      ollama: ['ollama'],
    },
  }

  return targets[packageManagerId] || {}
}

async function detectOutdatedPackages(packageManagerId) {
  if (packageManagerId === 'brew') {
    try {
      const result = await runProcess('brew', ['outdated', '--json=v2'], {
        env: getShellEnv(),
        timeoutMs: INSTALLER_DIAGNOSTIC_COMMAND_TIMEOUT_MS,
      })
      const parsed = JSON.parse(result.stdout || '{}')
      return new Set([
        ...(parsed.formulae || []).map((item) => item.name).filter(Boolean),
        ...(parsed.casks || []).map((item) => item.name).filter(Boolean),
      ])
    } catch {
      return new Set()
    }
  }

  if (packageManagerId === 'winget') {
    try {
      const result = await runProcess(
        'winget',
        ['upgrade', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity'],
        {
          env: getShellEnv(),
          timeoutMs: INSTALLER_DIAGNOSTIC_COMMAND_TIMEOUT_MS,
        }
      )
      const packages = new Set()

      for (const rawLine of result.stdout.split(/\r?\n/)) {
        const line = rawLine.trim()
        if (
          !line ||
          line.startsWith('Name ') ||
          line.startsWith('--') ||
          line.includes('No installed package')
        ) {
          continue
        }

        const columns = line.split(/\s{2,}/).map((segment) => segment.trim()).filter(Boolean)
        if (columns.length >= 2) {
          packages.add(columns[1])
        }
      }

      return packages
    } catch {
      return new Set()
    }
  }

  if (packageManagerId === 'choco') {
    try {
      const result = await runProcess('choco', ['outdated', '--limit-output'], {
        env: getShellEnv(),
        timeoutMs: INSTALLER_DIAGNOSTIC_COMMAND_TIMEOUT_MS,
      })
      return new Set(
        result.stdout
          .split(/\r?\n/)
          .map((line) => line.trim())
          .filter(Boolean)
          .map((line) => line.split('|')[0])
          .filter(Boolean)
      )
    } catch {
      return new Set()
    }
  }

  return new Set()
}

function parseVersionNumber(raw) {
  if (!raw) {
    return null
  }

  const match = raw.match(/v?(\d+(?:\.\d+){0,2})/i)
  return match ? match[1] : null
}

function compareVersions(left, right) {
  const leftParts = String(left || '')
    .split('.')
    .map((value) => Number.parseInt(value, 10) || 0)
  const rightParts = String(right || '')
    .split('.')
    .map((value) => Number.parseInt(value, 10) || 0)

  const maxLength = Math.max(leftParts.length, rightParts.length)
  for (let index = 0; index < maxLength; index += 1) {
    const leftPart = leftParts[index] || 0
    const rightPart = rightParts[index] || 0
    if (leftPart > rightPart) {
      return 1
    }
    if (leftPart < rightPart) {
      return -1
    }
  }

  return 0
}

async function detectCommandVersion(command, args = ['--version']) {
  try {
    const result = await runProcess(command, args, {
      env: getShellEnv(),
      timeoutMs: INSTALLER_DIAGNOSTIC_COMMAND_TIMEOUT_MS,
    })
    return parseVersionNumber(result.stdout || result.stderr)
  } catch {
    return null
  }
}

async function detectLatestNpmPackageVersion(packageName, npmBinary) {
  if (!packageName || !npmBinary) {
    return null
  }

  try {
    const result = await runProcess(npmBinary, ['view', packageName, 'version', '--json'], {
      env: getShellEnv(),
      timeoutMs: INSTALLER_DIAGNOSTIC_COMMAND_TIMEOUT_MS,
    })
    const raw = (result.stdout || '').trim()
    if (!raw) {
      return null
    }

    try {
      return parseVersionNumber(JSON.parse(raw))
    } catch {
      return parseVersionNumber(raw)
    }
  } catch {
    return null
  }
}

async function detectContainerRuntime(options = {}) {
  return detectRoachNetContainerRuntime({
    commandPath,
    commandExists: commandResponds,
    runProcess(binary, args = [], runOptions = {}) {
      return runProcess(binary, args, {
        timeoutMs: INSTALLER_DIAGNOSTIC_COMMAND_TIMEOUT_MS,
        ...runOptions,
      })
    },
    ...options,
  })
}

function buildPendingDependencySnapshot(config = {}) {
  const requiredIds = new Set(getRequiredDependencyIds(config))
  return {
    git: {
      id: 'git',
      label: 'Git',
      required: requiredIds.has('git'),
      available: false,
      path: null,
      version: null,
      minimumVersion: null,
      needsUpdate: false,
      detectionPending: true,
    },
    node: {
      id: 'node',
      label: 'Node.js 22+',
      required: requiredIds.has('node'),
      available: Boolean(getPreferredNodeBinary()),
      path: getPreferredNodeBinary(),
      version: null,
      minimumVersion: '22.0.0',
      needsUpdate: false,
      bundled: true,
      detectionPending: true,
    },
    npm: {
      id: 'npm',
      label: 'npm',
      required: requiredIds.has('npm'),
      available: Boolean(getPreferredNpmBinary(getPreferredNodeBinary())),
      path: getPreferredNpmBinary(getPreferredNodeBinary()),
      version: null,
      minimumVersion: null,
      needsUpdate: false,
      bundled: true,
      detectionPending: true,
    },
    docker: {
      id: 'docker',
      label: 'Docker',
      required: requiredIds.has('docker'),
      available: false,
      path: null,
      daemonRunning: false,
      version: null,
      minimumVersion: null,
      needsUpdate: false,
      detectionPending: true,
    },
    dockerCompose: {
      id: 'dockerCompose',
      label: 'Docker Compose',
      required: requiredIds.has('dockerCompose'),
      available: false,
      version: null,
      minimumVersion: '2.x',
      needsUpdate: false,
      detectionPending: true,
    },
    ollama: {
      id: 'ollama',
      label: 'Ollama',
      required: false,
      available: false,
      version: null,
      minimumVersion: null,
      needsUpdate: false,
      detectionPending: true,
    },
    openclaw: {
      id: 'openclaw',
      label: 'OpenClaw',
      required: false,
      available: false,
      path: null,
      version: null,
      minimumVersion: null,
      needsUpdate: false,
      detectionPending: true,
    },
  }
}

function buildPendingDiagnostics(config = {}) {
  return {
    packageManager: {
      id: 'checking',
      label: 'Checking',
    },
    containerRuntime: {
      integrationName: 'RoachNet Container Runtime',
      dockerCliPath: null,
      composeAvailable: false,
      daemonRunning: false,
      desktopCapable: process.platform === 'darwin' || process.platform === 'win32',
      desktopCliAvailable: false,
      desktopStatus: 'checking',
      ready: false,
      docs: DOCKER_DOCS,
      detectionPending: true,
    },
    dependencies: buildPendingDependencySnapshot(config),
  }
}

function queueInstallerDiagnosticsRefresh(config = {}) {
  if (runtimeState.diagnosticsCache.refreshPromise) {
    return runtimeState.diagnosticsCache.refreshPromise
  }

  runtimeState.diagnosticsCache.refreshPromise = (async () => {
    try {
      const packageManager = await detectPackageManager()
      const containerRuntime = await detectContainerRuntime()
      const dependencies = await detectDependencies({ containerRuntime, includeUpdateChecks: false })
      runtimeState.diagnosticsCache.value = {
        packageManager,
        containerRuntime,
        dependencies,
      }
      runtimeState.diagnosticsCache.expiresAt = Date.now() + INSTALLER_DIAGNOSTICS_CACHE_TTL_MS
    } catch (error) {
      if (!runtimeState.diagnosticsCache.value) {
        runtimeState.diagnosticsCache.value = buildPendingDiagnostics(config)
      }
      runtimeState.diagnosticsCache.expiresAt = Date.now() + 2_000
      console.error('[roachnet-setup] diagnostics refresh failed:', error)
    } finally {
      runtimeState.diagnosticsCache.refreshPromise = null
    }
  })()

  return runtimeState.diagnosticsCache.refreshPromise
}

function describePlatform() {
  const labels = {
    darwin: 'macOS',
    linux: 'Linux',
    win32: 'Windows',
  }

  return {
    os: process.platform,
    osLabel: labels[process.platform] || process.platform,
    arch: process.arch,
    hostname: os.hostname(),
    recommendedProfile: 'portable',
  }
}

async function detectDependencies({ containerRuntime, includeUpdateChecks = false } = {}) {
  const packageManager = await detectPackageManager()
  const outdatedPackages = includeUpdateChecks
    ? await detectOutdatedPackages(packageManager.id)
    : new Set()
  const gitPath = await commandPath('git')
  const bundledNodePath = getPreferredNodeBinary() || 'node'
  const bundledNpmPath =
    getPreferredNpmBinary(bundledNodePath) || (process.platform === 'win32' ? 'npm.cmd' : 'npm')
  const nodePath = (await commandPath('node')) || (existsSync(bundledNodePath) ? bundledNodePath : null)
  const npmPath =
    (await commandPath(process.platform === 'win32' ? 'npm.cmd' : 'npm')) ||
    ((typeof bundledNpmPath === 'string' &&
      (!bundledNpmPath.includes(path.sep) || existsSync(bundledNpmPath)))
      ? bundledNpmPath
      : null)
  const openclawPath = await commandPath(process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw')
  const resolvedContainerRuntime =
    containerRuntime ||
    (await detectContainerRuntime({
      commandExists: commandResponds,
    }))
  const ollamaAvailablePromise = commandExists('ollama')
  const openclawAvailablePromise = Boolean(openclawPath)
    ? Promise.resolve(true)
    : commandExists(process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw')
  const [
    gitVersion,
    nodeVersion,
    npmVersion,
    ollamaAvailable,
    openclawAvailable,
    dockerVersion,
    dockerComposeVersion,
  ] = await Promise.all([
    gitPath ? detectCommandVersion('git', ['--version']) : Promise.resolve(null),
    nodePath ? detectCommandVersion(nodePath, ['--version']) : Promise.resolve(null),
    npmPath ? detectCommandVersion(npmPath, ['--version']) : Promise.resolve(null),
    ollamaAvailablePromise,
    openclawAvailablePromise,
    resolvedContainerRuntime.dockerCliPath
      ? detectCommandVersion('docker', ['--version'])
      : Promise.resolve(null),
    resolvedContainerRuntime.composeAvailable
      ? detectCommandVersion('docker', ['compose', 'version'])
      : Promise.resolve(null),
  ])
  const [ollamaVersion, openclawVersion, latestOpenclawVersion] = await Promise.all([
    ollamaAvailable ? detectCommandVersion('ollama', ['--version']) : Promise.resolve(null),
    openclawAvailable
      ? detectCommandVersion(
          openclawPath || (process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw'),
          ['--version']
        )
      : Promise.resolve(null),
    includeUpdateChecks && openclawAvailable
      ? detectLatestNpmPackageVersion('openclaw', npmPath)
      : Promise.resolve(null),
  ])
  const minimumNodeVersion = '22.0.0'
  const nodeNeedsUpdate =
    Boolean(nodeVersion) && compareVersions(nodeVersion, minimumNodeVersion) < 0
  const packageTargets = getDependencyPackageTargets(packageManager.id)
  const bundledNodeResolvedPath =
    typeof bundledNodePath === 'string' && bundledNodePath.includes(path.sep)
      ? path.resolve(bundledNodePath)
      : null
  const bundledNpmResolvedPath =
    typeof bundledNpmPath === 'string' && bundledNpmPath.includes(path.sep) && existsSync(bundledNpmPath)
      ? path.resolve(bundledNpmPath)
      : null
  const nodeResolvedPath = nodePath && nodePath.includes(path.sep) ? path.resolve(nodePath) : null
  const npmResolvedPath = npmPath && npmPath.includes(path.sep) ? path.resolve(npmPath) : null
  const usingBundledNode = Boolean(nodeResolvedPath && bundledNodeResolvedPath && nodeResolvedPath === bundledNodeResolvedPath)
  const usingBundledNpm = Boolean(npmResolvedPath && bundledNpmResolvedPath && npmResolvedPath === bundledNpmResolvedPath)
  const hasPackageUpdate = (dependencyId) =>
    (packageTargets[dependencyId] || []).some((packageName) => outdatedPackages.has(packageName))
  const openclawNeedsUpdate =
    Boolean(openclawVersion) &&
    Boolean(latestOpenclawVersion) &&
    compareVersions(openclawVersion, latestOpenclawVersion) < 0

  return {
    git: {
      id: 'git',
      label: 'Git',
      required: true,
      available: Boolean(gitPath),
      path: gitPath,
      version: gitVersion,
      minimumVersion: null,
      needsUpdate: hasPackageUpdate('git'),
    },
    node: {
      id: 'node',
      label: 'Node.js 22+',
      required: true,
      available: Boolean(nodePath),
      path: nodePath,
      version: nodeVersion,
      minimumVersion: minimumNodeVersion,
      needsUpdate: nodeNeedsUpdate || (!usingBundledNode && hasPackageUpdate('node')),
      bundled: usingBundledNode,
    },
    npm: {
      id: 'npm',
      label: 'npm',
      required: true,
      available: Boolean(npmPath),
      path: npmPath,
      version: npmVersion,
      minimumVersion: null,
      needsUpdate: !usingBundledNpm && hasPackageUpdate('npm'),
      bundled: usingBundledNpm,
    },
    docker: {
      id: 'docker',
      label: 'Docker',
      required: true,
      available: Boolean(resolvedContainerRuntime.dockerCliPath),
      path: resolvedContainerRuntime.dockerCliPath,
      daemonRunning: resolvedContainerRuntime.daemonRunning,
      version: dockerVersion,
      minimumVersion: null,
      needsUpdate: hasPackageUpdate('docker'),
    },
    dockerCompose: {
      id: 'dockerCompose',
      label: 'Docker Compose',
      required: true,
      available: resolvedContainerRuntime.composeAvailable,
      version: dockerComposeVersion,
      minimumVersion: '2.x',
      needsUpdate: hasPackageUpdate('dockerCompose'),
    },
    ollama: {
      id: 'ollama',
      label: 'Ollama',
      required: false,
      available: ollamaAvailable,
      version: ollamaVersion,
      minimumVersion: null,
      needsUpdate: hasPackageUpdate('ollama'),
    },
    openclaw: {
      id: 'openclaw',
      label: 'OpenClaw',
      required: false,
      available: openclawAvailable,
      path: openclawPath,
      version: openclawVersion,
      minimumVersion: latestOpenclawVersion,
      needsUpdate: openclawNeedsUpdate,
    },
  }
}

function getEffectiveSourceMode(config = {}) {
  const explicitSourceMode = typeof config.sourceMode === 'string' ? config.sourceMode.trim() : ''
  return explicitSourceMode || getDefaultConfig().sourceMode
}

function getRequiredDependencyIds(config = {}) {
  if (getEffectiveSourceMode(config) === 'clone') {
    return ['git']
  }

  return []
}

function getManagedDependencyIds(config = {}) {
  return [...new Set(getRequiredDependencyIds(config))]
}

function applyDependencyRequirements(dependencies, config = {}) {
  const requiredIds = new Set(getRequiredDependencyIds(config))

  return Object.fromEntries(
    Object.entries(dependencies).map(([dependencyId, dependency]) => [
      dependencyId,
      {
        ...dependency,
        required: requiredIds.has(dependencyId),
      },
    ])
  )
}

function getDependencyInstallCommand(packageManagerId, dependencyId) {
  const commands = {
    brew: {
      git: 'brew upgrade git || brew install git',
      node: 'brew upgrade node@22 || brew install node@22',
      docker: 'brew upgrade --cask docker || brew install --cask docker',
      dockerCompose: 'brew upgrade --cask docker || brew install --cask docker',
      ollama: 'brew upgrade ollama || brew install ollama',
      openclaw: 'npm install -g openclaw@latest',
    },
    apt: {
      git: 'sudo apt-get update && sudo apt-get install -y git curl ca-certificates',
      node:
        'curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs',
      docker: 'curl -fsSL https://get.docker.com | sudo sh',
      dockerCompose: 'sudo apt-get update && sudo apt-get install -y docker-compose-plugin',
      ollama: 'curl -fsSL https://ollama.com/install.sh | sh',
      openclaw: 'npm install -g openclaw@latest',
    },
    dnf: {
      git: 'sudo dnf install -y git curl ca-certificates',
      node: 'curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash - && sudo dnf install -y nodejs',
      docker: 'curl -fsSL https://get.docker.com | sudo sh',
      dockerCompose: 'sudo dnf install -y docker-compose-plugin || sudo dnf install -y docker-compose',
      ollama: 'curl -fsSL https://ollama.com/install.sh | sh',
      openclaw: 'npm install -g openclaw@latest',
    },
    yum: {
      git: 'sudo yum install -y git curl ca-certificates',
      node: 'curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash - && sudo yum install -y nodejs',
      docker: 'curl -fsSL https://get.docker.com | sudo sh',
      dockerCompose: 'sudo yum install -y docker-compose-plugin || sudo yum install -y docker-compose',
      ollama: 'curl -fsSL https://ollama.com/install.sh | sh',
      openclaw: 'npm install -g openclaw@latest',
    },
    pacman: {
      git: 'sudo pacman -Sy --noconfirm git curl ca-certificates',
      node: 'sudo pacman -Sy --noconfirm nodejs npm',
      docker: 'sudo pacman -Sy --noconfirm docker docker-compose',
      dockerCompose: 'sudo pacman -Sy --noconfirm docker docker-compose',
      ollama: 'sudo pacman -Sy --noconfirm ollama',
      openclaw: 'npm install -g openclaw@latest',
    },
    zypper: {
      git: 'sudo zypper install -y git curl ca-certificates',
      node: 'sudo zypper install -y nodejs22 npm22',
      docker: 'sudo zypper install -y docker docker-compose',
      dockerCompose: 'sudo zypper install -y docker-compose',
      ollama: null,
      openclaw: 'npm install -g openclaw@latest',
    },
    winget: {
      git: 'winget upgrade --id Git.Git -e --source winget || winget install --id Git.Git -e --source winget',
      node: 'winget upgrade --id OpenJS.NodeJS.LTS -e --source winget || winget install --id OpenJS.NodeJS.LTS -e --source winget',
      docker: 'winget upgrade --id Docker.DockerDesktop -e --source winget || winget install --id Docker.DockerDesktop -e --source winget',
      dockerCompose: 'winget upgrade --id Docker.DockerDesktop -e --source winget || winget install --id Docker.DockerDesktop -e --source winget',
      ollama: 'winget upgrade --id Ollama.Ollama -e --source winget || winget install --id Ollama.Ollama -e --source winget',
      openclaw: 'npm install -g openclaw@latest',
    },
    choco: {
      git: 'choco upgrade git -y || choco install git -y',
      node: 'choco upgrade nodejs-lts -y || choco install nodejs-lts -y',
      docker: 'choco upgrade docker-desktop -y || choco install docker-desktop -y',
      dockerCompose: 'choco upgrade docker-desktop -y || choco install docker-desktop -y',
      ollama: null,
      openclaw: 'npm install -g openclaw@latest',
    },
  }

  return commands[packageManagerId]?.[dependencyId] || null
}

function dependencyInstallNeedsPrivileges(packageManagerId, dependencyId) {
  if (
    process.platform === 'darwin' &&
    packageManagerId === 'brew' &&
    ['docker', 'dockerCompose'].includes(dependencyId)
  ) {
    return true
  }

  if (process.platform === 'win32' && ['winget', 'choco'].includes(packageManagerId)) {
    return ['docker', 'dockerCompose'].includes(dependencyId)
  }

  if (['apt', 'dnf', 'yum', 'pacman', 'zypper'].includes(packageManagerId)) {
    return true
  }

  return false
}

function getDependencyNotes(packageManagerId, dependencyId) {
  if (dependencyId === 'docker') {
    return 'Docker stays optional for the contained install lane. RoachNet can still boot into the local-first shell without it.'
  }

  if (dependencyId === 'node') {
    return 'RoachNet Setup bundles its own Node runtime, so this Mac does not need a separate global Node install.'
  }

  if (dependencyId === 'openclaw' && process.platform === 'win32') {
    return 'OpenClaw documentation recommends Windows users run the CLI in WSL2 for the most complete support.'
  }

  return null
}

function getDefaultConfig(overrides = {}) {
  const persistedConfig = loadPersistedInstallerConfig()
  const persistedInstallPath = normalizeInputPath(
    persistedConfig.installPath || getDefaultInstallPath()
  )
  const hasInstallPathOverride =
    typeof overrides.installPath === 'string' && overrides.installPath.trim().length > 0
  const hasStoragePathOverride =
    typeof overrides.storagePath === 'string' && overrides.storagePath.trim().length > 0
  const defaultInstallPath = normalizeInputPath(
    overrides.installPath || persistedConfig.installPath || getDefaultInstallPath()
  )
  const defaultSourceMode = hasCurrentWorkspaceSource()
    ? existsSync(path.join(repoRoot, '.git'))
      ? 'current-workspace'
      : 'bundled'
    : 'clone'
  const installRoachClaw =
    persistedConfig.installRoachClaw === undefined
      ? true
      : Boolean(persistedConfig.installRoachClaw)
  const installPath = normalizeInputPath(defaultInstallPath)
  const installedAppPath = getCanonicalInstalledAppPath(installPath)
  const shouldReusePersistedStoragePath =
    !hasInstallPathOverride || installPath === persistedInstallPath
  const storagePath = normalizeInputPath(
    hasStoragePathOverride
      ? overrides.storagePath
      : shouldReusePersistedStoragePath
        ? persistedConfig.storagePath || path.join(installPath, 'storage')
        : path.join(installPath, 'storage')
  )
  const installLooksPresent =
    existsSync(path.join(installPath, 'scripts', 'run-roachnet.mjs')) &&
    existsSync(path.join(installPath, 'admin', 'package.json')) &&
    existsSync(installedAppPath)
  const sanitizedOverrides = stripUndefinedEntries({
    ...overrides,
    installPath,
    installedAppPath,
    appInstallPath: installedAppPath,
    storagePath,
  })

  return {
    installPath,
    installedAppPath,
    appInstallPath: installedAppPath,
    sourceMode: overrides.sourceMode || persistedConfig.sourceMode || defaultSourceMode,
    sourceRepoUrl: overrides.sourceRepoUrl || persistedConfig.sourceRepoUrl || DEFAULT_SOURCE_REPO_URL,
    sourceRef: overrides.sourceRef || persistedConfig.sourceRef || DEFAULT_SOURCE_REF,
    autoInstallDependencies:
      persistedConfig.autoInstallDependencies === undefined
        ? false
        : Boolean(persistedConfig.autoInstallDependencies),
    useDockerContainerization:
      overrides.useDockerContainerization === undefined
        ? Boolean(persistedConfig.useDockerContainerization)
        : Boolean(overrides.useDockerContainerization),
    installRoachClaw,
    roachClawDefaultModel:
      typeof persistedConfig.roachClawDefaultModel === 'string' &&
      persistedConfig.roachClawDefaultModel.trim()
        ? persistedConfig.roachClawDefaultModel.trim()
        : DEFAULT_ROACHCLAW_MODEL,
    installOptionalOllama: installRoachClaw,
    installOptionalOpenClaw: installRoachClaw,
    autoLaunch: persistedConfig.autoLaunch === undefined ? true : Boolean(persistedConfig.autoLaunch),
    releaseChannel: persistedConfig.releaseChannel || 'stable',
    updateBaseUrl: persistedConfig.updateBaseUrl || '',
    autoCheckUpdates:
      persistedConfig.autoCheckUpdates === undefined ? true : Boolean(persistedConfig.autoCheckUpdates),
    autoDownloadUpdates: Boolean(persistedConfig.autoDownloadUpdates),
    launchAtLogin: Boolean(persistedConfig.launchAtLogin),
    dryRun: Boolean(persistedConfig.dryRun),
    installOptionalMlx: Boolean(persistedConfig.installOptionalMlx),
    appleAccelerationBackend: persistedConfig.appleAccelerationBackend || 'auto',
    mlxBaseUrl: persistedConfig.mlxBaseUrl || 'http://127.0.0.1:8080',
    mlxModelId: persistedConfig.mlxModelId || '',
    distributedInferenceBackend: persistedConfig.distributedInferenceBackend || 'disabled',
    exoBaseUrl: persistedConfig.exoBaseUrl || 'http://127.0.0.1:52415',
    exoModelId: persistedConfig.exoModelId || '',
    exoNodeRole: persistedConfig.exoNodeRole || 'auto',
    exoAutoStart: Boolean(persistedConfig.exoAutoStart),
    setupCompletedAt: installLooksPresent ? persistedConfig.setupCompletedAt || null : null,
    pendingLaunchIntro: installLooksPresent ? Boolean(persistedConfig.pendingLaunchIntro) : false,
    pendingRoachClawSetup: installLooksPresent ? Boolean(persistedConfig.pendingRoachClawSetup) : false,
    roachClawOnboardingCompletedAt: persistedConfig.roachClawOnboardingCompletedAt || null,
    introCompletedAt: persistedConfig.introCompletedAt || null,
    lastLaunchUrl: installLooksPresent ? persistedConfig.lastLaunchUrl || null : null,
    lastOpenedMode: persistedConfig.lastOpenedMode || 'setup',
    preferredShell: persistedConfig.preferredShell || 'native',
    storagePath,
    ...sanitizedOverrides,
  }
}

async function canBindPort(port, host = SERVER_HOST) {
  return new Promise((resolve) => {
    const server = net.createServer()
    server.once('error', () => resolve(false))
    server.once('listening', () => {
      server.close(() => resolve(true))
    })
    server.listen(port, host)
  })
}

async function findAvailablePort(startPort, host = SERVER_HOST) {
  let port = startPort

  while (!(await canBindPort(port, host))) {
    port += 1
  }

  return port
}

async function isPortOpen(host, port) {
  return new Promise((resolve) => {
    const socket = new net.Socket()
    const handleFailure = () => {
      socket.destroy()
      resolve(false)
    }

    socket.setTimeout(700)
    socket.once('connect', () => {
      socket.destroy()
      resolve(true)
    })
    socket.once('error', handleFailure)
    socket.once('timeout', handleFailure)
    socket.connect(port, host)
  })
}

async function waitForPorts(ports, log) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < PORT_WAIT_TIMEOUT_MS) {
    const results = await Promise.all(ports.map((target) => isPortOpen(target.host, target.port)))

    if (results.every(Boolean)) {
      return
    }

    log(
      `Waiting for support services on ${ports
        .map((target) => `${target.host}:${target.port}`)
        .join(', ')}...`
    )
    await new Promise((resolve) => setTimeout(resolve, PORT_WAIT_INTERVAL_MS))
  }

  throw new Error('Timed out while waiting for RoachNet support services to become reachable.')
}

async function waitForHttpOk(url, timeoutMs) {
  const startedAt = Date.now()
  let lastError = null

  while (Date.now() - startedAt < timeoutMs) {
    const controller = new AbortController()
    const timeoutHandle = setTimeout(() => controller.abort(), 3_000)

    try {
      const response = await fetch(url, {
        headers: { Accept: 'application/json' },
        signal: controller.signal,
      })

      if (response.ok) {
        clearTimeout(timeoutHandle)
        return true
      }

      lastError = `${response.status} ${response.statusText}`
    } catch (error) {
      lastError = error?.message || 'request failed'
    } finally {
      clearTimeout(timeoutHandle)
    }

    await new Promise((resolve) => setTimeout(resolve, PORT_WAIT_INTERVAL_MS))
  }

  throw new Error(
    `Timed out while waiting for ${url} to answer successfully${lastError ? ` (${lastError})` : ''}.`
  )
}

async function waitForChildExit(child, timeoutMs) {
  if (!child || child.exitCode !== null) {
    return child?.exitCode ?? 0
  }

  return new Promise((resolve) => {
    let resolved = false
    const timeoutHandle =
      timeoutMs > 0
        ? setTimeout(() => {
            if (resolved) {
              return
            }

            resolved = true
            resolve(null)
          }, timeoutMs)
        : null

    child.once('close', (code) => {
      if (resolved) {
        return
      }

      resolved = true
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }
      resolve(code)
    })
  })
}

function getPreferredNodeBinary() {
  const candidates = [
    process.env.ROACHNET_NODE_BINARY,
    process.execPath,
    '/opt/homebrew/opt/node@22/bin/node',
    '/usr/local/opt/node@22/bin/node',
    'node',
  ]

  return (
    candidates.find(
      (candidate) =>
        typeof candidate === 'string' &&
        candidate.length > 0 &&
        (candidate === 'node' || existsSync(candidate))
    ) || 'node'
  )
}

function getPreferredNpmBinary(nodeBinary = getPreferredNodeBinary()) {
  const normalizedNodeBinary = typeof nodeBinary === 'string' && nodeBinary.length > 0 ? nodeBinary : 'node'
  const localNodeNpm =
    normalizedNodeBinary.includes(path.sep)
      ? path.join(path.dirname(normalizedNodeBinary), process.platform === 'win32' ? 'npm.cmd' : 'npm')
      : null
  const candidatePaths = [
    localNodeNpm,
    process.env.ROACHNET_NPM_BINARY,
    '/opt/homebrew/opt/node@22/bin/npm',
    '/usr/local/opt/node@22/bin/npm',
    process.platform === 'win32' ? 'npm.cmd' : 'npm',
  ]

  return (
    candidatePaths.find(
      (candidate) =>
        typeof candidate === 'string' &&
        candidate.length > 0 &&
        (!candidate.includes(path.sep) || existsSync(candidate))
    ) || (process.platform === 'win32' ? 'npm.cmd' : 'npm')
  )
}

function resolveInstalledAppNodeBinary(configOrInstallPath, installedAppPath) {
  const installPath =
    typeof configOrInstallPath === 'string'
      ? normalizeInputPath(configOrInstallPath)
      : normalizeInputPath(configOrInstallPath?.installPath || getDefaultInstallPath())
  const appPath = normalizeInputPath(
    installedAppPath ||
      (typeof configOrInstallPath === 'object' && configOrInstallPath?.installedAppPath) ||
      getCanonicalInstalledAppPath(installPath)
  )

  const candidates = [
    path.join(appPath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node', 'bin', 'node'),
    path.join(
      installPath,
      'app',
      'RoachNet.app',
      'Contents',
      'Resources',
      'EmbeddedRuntime',
      'node',
      'bin',
      'node'
    ),
    getPreferredNodeBinary(),
  ]

  return candidates.find((candidate) => candidate && existsSync(candidate)) || getPreferredNodeBinary()
}

function getShellEnv() {
  const preferredNodeBinary = getPreferredNodeBinary()
  const preferredNodeBin =
    typeof preferredNodeBinary === 'string' && preferredNodeBinary.includes(path.sep)
    ? path.dirname(preferredNodeBinary)
    : null
  const localBinPath = process.env.ROACHNET_LOCAL_BIN_PATH || path.join(repoRoot, 'bin')

  return {
    ...process.env,
    HOME: os.homedir(),
    PATH: [
      localBinPath,
      preferredNodeBin,
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/opt/homebrew/opt/node@22/bin',
      '/usr/local/opt/node@22/bin',
      process.env.PATH || '',
    ]
      .filter(Boolean)
      .join(path.delimiter),
  }
}

function getLocalBinRoot(repoPath = repoRoot) {
  return normalizeInputPath(process.env.ROACHNET_LOCAL_BIN_PATH || path.join(repoPath, 'bin'))
}

function getLocalToolBinaryPath(toolName, repoPath = repoRoot) {
  const base = getLocalBinRoot(repoPath)
  const fileName = process.platform === 'win32' ? `${toolName}.cmd` : toolName
  return path.join(base, fileName)
}

function formatByteCount(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return '0 B'
  }

  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let value = bytes
  let unitIndex = 0

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024
    unitIndex += 1
  }

  const precision = value >= 10 || unitIndex === 0 ? 0 : 1
  return `${value.toFixed(precision)} ${units[unitIndex]}`
}

function resolveExistingProbePath(targetPath) {
  let probePath = normalizeInputPath(targetPath)

  while (probePath && !existsSync(probePath)) {
    const parentPath = path.dirname(probePath)
    if (parentPath === probePath) {
      break
    }
    probePath = parentPath
  }

  return existsSync(probePath) ? probePath : os.homedir()
}

async function getAvailableDiskBytes(targetPath) {
  const probePath = resolveExistingProbePath(targetPath)
  const filesystemStats = await statfs(probePath)
  return Number(filesystemStats.bavail) * Number(filesystemStats.bsize)
}

function getRequiredInstallHeadroomBytes(config) {
  return config.installRoachClaw === false
    ? MIN_FREE_BYTES_BASE_INSTALL
    : MIN_FREE_BYTES_WITH_ROACHCLAW
}

async function ensureInstallVolumeHeadroom(config, task) {
  const availableBytes = await getAvailableDiskBytes(config.installPath)
  const requiredBytes = getRequiredInstallHeadroomBytes(config)

  appendTaskLog(
    task,
    `Install volume has ${formatByteCount(availableBytes)} free. This setup pass needs about ${formatByteCount(requiredBytes)}.`
  )

  if (availableBytes < requiredBytes) {
    const aiHint =
      config.installRoachClaw === false
        ? 'for the base contained install'
        : 'for the base install plus the first contained AI lane'
    throw new Error(
      `RoachNet needs about ${formatByteCount(requiredBytes)} free on the selected install volume ${aiHint}. Only ${formatByteCount(availableBytes)} is free right now. Choose a roomier install root or turn off Install RoachClaw for the first pass.`
    )
  }
}

function sanitizeInstallerErrorMessage(error, config) {
  const rawMessage =
    typeof error?.message === 'string' ? error.message : String(error || 'RoachNet Setup failed.')

  if (/ENOSPC|no space left on device/i.test(rawMessage)) {
    const requiredBytes = getRequiredInstallHeadroomBytes(config)
    return `RoachNet ran out of disk space while staging the contained install. Free up more space, choose a roomier install root, or turn off Install RoachClaw for the first pass. This setup pass expects about ${formatByteCount(requiredBytes)} free on the selected volume.`
  }

  const replacements = [
    config?.installPath,
    config?.storagePath,
    config?.installedAppPath,
    repoRoot,
    os.homedir(),
  ]
    .filter((value) => typeof value === 'string' && value.length > 0)
    .map((value) => normalizeInputPath(value))
    .sort((left, right) => right.length - left.length)

  return replacements.reduce(
    (message, candidatePath) => message.split(candidatePath).join('RoachNet root'),
    rawMessage
  )
}

async function symlinkOrCopyToolBinary(sourcePath, destinationPath) {
  await rm(destinationPath, { force: true }).catch(() => {})
  await ensureDirectory(path.dirname(destinationPath))

  try {
    const relativeSourcePath = path.relative(path.dirname(destinationPath), sourcePath)
    await symlink(relativeSourcePath || sourcePath, destinationPath)
  } catch {
    await copyFile(sourcePath, destinationPath)
    await chmod(destinationPath, 0o755).catch(() => {})
  }
}

async function downloadToFile(url, destinationPath) {
  return downloadFile(url, destinationPath)
}

async function getLatestOllamaRelease() {
  try {
    const release = await fetchJson(OLLAMA_RELEASE_API_URL)
    const asset = Array.isArray(release.assets)
      ? release.assets.find((entry) => entry?.name === 'ollama-darwin.tgz')
      : null

    return {
      version: parseVersionNumber(release.tag_name) || OLLAMA_FALLBACK_VERSION,
      url: asset?.browser_download_url || OLLAMA_DIRECT_DOWNLOAD_URL,
      assetName: asset?.name || path.basename(new URL(OLLAMA_DIRECT_DOWNLOAD_URL).pathname) || 'ollama-darwin.tgz',
    }
  } catch (error) {
    appendTrace(
      'setup.install.ollama_release_fallback',
      error instanceof Error ? error.message : String(error)
    )

    return {
      version: OLLAMA_FALLBACK_VERSION,
      url: OLLAMA_DIRECT_DOWNLOAD_URL,
      assetName: path.basename(new URL(OLLAMA_DIRECT_DOWNLOAD_URL).pathname) || 'ollama-darwin.tgz',
    }
  }
}

function readBundledPackageVersion(packageRoot, packageName) {
  const packageJsonPath = path.join(packageRoot, 'node_modules', packageName, 'package.json')
  if (!existsSync(packageJsonPath)) {
    return null
  }

  try {
    const contents = JSON.parse(readFileSync(packageJsonPath, 'utf8'))
    return parseVersionNumber(contents?.version) || contents?.version || null
  } catch {
    return null
  }
}

async function clearMacLaunchMetadata(targetPath) {
  if (process.platform !== 'darwin' || !targetPath || !existsSync(targetPath)) {
    return
  }

  for (const args of [
    ['-dr', 'com.apple.provenance', targetPath],
    ['-dr', 'com.apple.quarantine', targetPath],
    ['-cr', targetPath],
  ]) {
    try {
      await runProcess('xattr', args, {
        env: getShellEnv(),
        timeoutMs: 10_000,
      })
    } catch {
      // Best-effort cleanup only.
    }
  }
}

async function ensureContainedOpenClaw(repoPath, task) {
  const localBinaryPath = getLocalToolBinaryPath('openclaw', repoPath)
  const currentVersion = existsSync(localBinaryPath)
    ? await detectCommandVersion(localBinaryPath, ['--version'])
    : null
  const packageRoot = path.join(repoPath, 'runtime', 'vendor', 'openclaw')
  const installedBinaryPath = path.join(
    packageRoot,
    'node_modules',
    '.bin',
    process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw'
  )
  const bundledVersion = readBundledPackageVersion(packageRoot, 'openclaw')

  if (existsSync(installedBinaryPath)) {
    await symlinkOrCopyToolBinary(installedBinaryPath, localBinaryPath)
    appendTaskLog(
      task,
      `Contained OpenClaw is ready from the bundled payload${bundledVersion ? ` (${bundledVersion})` : ''}.`
    )
    return localBinaryPath
  }

  const bundledInstallerPayload = getBundledInstallerAssetPath('bundled-openclaw')
  const bundledInstallerBinaryPath = bundledInstallerPayload
    ? path.join(
        bundledInstallerPayload,
        'node_modules',
        '.bin',
        process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw'
      )
    : null
  if (bundledInstallerPayload && bundledInstallerBinaryPath && existsSync(bundledInstallerBinaryPath)) {
    appendTaskLog(task, 'Hydrating contained OpenClaw from installer assets...')
    await installDirectoryArtifact(bundledInstallerPayload, packageRoot)
    await symlinkOrCopyToolBinary(installedBinaryPath, localBinaryPath)
    appendTaskLog(task, 'Contained OpenClaw linked from bundled installer assets.')
    return localBinaryPath
  }

  const nodeBinary = getPreferredNodeBinary()
  const npmBinary = getPreferredNpmBinary(nodeBinary)
  const latestVersion = await detectLatestNpmPackageVersion('openclaw', npmBinary)
  const needsInstall =
    !existsSync(localBinaryPath) ||
    !currentVersion ||
    (latestVersion && compareVersions(currentVersion, latestVersion) < 0)

  if (!needsInstall) {
    appendTaskLog(
      task,
      `Contained OpenClaw is ready${currentVersion ? ` (${currentVersion})` : ''}.`
    )
    return localBinaryPath
  }

  const packageJsonPath = path.join(packageRoot, 'package.json')
  const packageName = latestVersion ? `openclaw@${latestVersion}` : 'openclaw@latest'
  const setupWorkspaceRoot = getSetupWorkspaceRoot({ installPath: repoPath })
  const npmCacheRoot = path.join(setupWorkspaceRoot, 'npm-cache')
  const tempRoot = path.join(setupWorkspaceRoot, 'tmp')

  appendTaskLog(task, `Installing contained OpenClaw into ${packageRoot}...`)
  await ensureDirectory(packageRoot)
  await ensureDirectory(npmCacheRoot)
  await ensureDirectory(tempRoot)
  if (!existsSync(packageJsonPath)) {
    writeFileSync(
      packageJsonPath,
      JSON.stringify(
        {
          name: 'roachnet-contained-openclaw',
          private: true,
        },
        null,
        2
      ) + '\n',
      'utf8'
    )
  }

  await runProcess(
    npmBinary,
    ['install', '--prefix', packageRoot, '--no-audit', '--no-fund', '--omit=dev', packageName],
    {
      cwd: repoPath,
      env: {
        ...getShellEnv(),
        npm_config_update_notifier: 'false',
        npm_config_fund: 'false',
        npm_config_audit: 'false',
        npm_config_cache: npmCacheRoot,
        TMPDIR: tempRoot,
        TMP: tempRoot,
        TEMP: tempRoot,
      },
      timeoutMs: 300_000,
      onStdout(text) {
        for (const line of text.split(/\r?\n/).filter(Boolean)) {
          appendTaskLog(task, line)
        }
      },
      onStderr(text) {
        for (const line of text.split(/\r?\n/).filter(Boolean)) {
          appendTaskLog(task, line)
        }
      },
    }
  )

  if (!existsSync(installedBinaryPath)) {
    throw new Error(`Contained OpenClaw install completed without a launchable binary at ${installedBinaryPath}.`)
  }

  await symlinkOrCopyToolBinary(installedBinaryPath, localBinaryPath)
  appendTaskLog(task, `Contained OpenClaw linked at ${localBinaryPath}.`)
  return localBinaryPath
}

async function ensureContainedOllama(repoPath, task) {
  if (!(process.platform === 'darwin' && process.arch === 'arm64')) {
    appendTaskLog(task, 'Contained Ollama downloads are currently only automated for Apple Silicon macOS.')
    return null
  }

  const localBinaryPath = getLocalToolBinaryPath('ollama', repoPath)
  const currentVersion = existsSync(localBinaryPath)
    ? await detectCommandVersion(localBinaryPath, ['--version'])
    : null
  const latestRelease = await getLatestOllamaRelease()
  const needsInstall =
    !existsSync(localBinaryPath) ||
    !currentVersion ||
    (latestRelease.version && compareVersions(currentVersion, latestRelease.version) < 0)

  if (!needsInstall) {
    appendTaskLog(
      task,
      `Contained Ollama is ready${currentVersion ? ` (${currentVersion})` : ''}.`
    )
    return localBinaryPath
  }

  const vendorRoot = path.join(repoPath, 'runtime', 'vendor', 'ollama')
  const bundledBinaryPath = path.join(vendorRoot, process.platform === 'win32' ? 'ollama.exe' : 'ollama')
  if (existsSync(bundledBinaryPath)) {
    await symlinkOrCopyToolBinary(bundledBinaryPath, localBinaryPath)
    appendTaskLog(
      task,
      `Contained Ollama is ready from the bundled payload${currentVersion ? ` (${currentVersion})` : ''}.`
    )
    return localBinaryPath
  }

  const bundledInstallerPayload = getBundledInstallerAssetPath('bundled-ollama')
  const bundledInstallerBinaryPath = bundledInstallerPayload
    ? path.join(bundledInstallerPayload, process.platform === 'win32' ? 'ollama.exe' : 'ollama')
    : null
  if (bundledInstallerPayload && bundledInstallerBinaryPath && existsSync(bundledInstallerBinaryPath)) {
    appendTaskLog(task, 'Hydrating contained Ollama from installer assets...')
    await installDirectoryArtifact(bundledInstallerPayload, vendorRoot)
    await clearMacLaunchMetadata(vendorRoot)
    await symlinkOrCopyToolBinary(bundledBinaryPath, localBinaryPath)
    appendTaskLog(task, 'Contained Ollama linked from bundled installer assets.')
    return localBinaryPath
  }

  const downloadRoot = await createSetupTempDirectory({ installPath: repoPath }, 'roachnet-ollama')
  const archivePath = path.join(downloadRoot, latestRelease.assetName || 'ollama-darwin.tgz')
  const unpackRoot = path.join(downloadRoot, 'unpacked')

  appendTaskLog(
    task,
    `Downloading contained Ollama${latestRelease.version ? ` ${latestRelease.version}` : ''}...`
  )

  try {
    await downloadToFile(latestRelease.url, archivePath)
    await ensureDirectory(unpackRoot)
    await runProcess('tar', ['-xzf', archivePath, '-C', unpackRoot], {
      env: getShellEnv(),
      timeoutMs: 300_000,
    })

    const extractedBinaryPath = path.join(unpackRoot, process.platform === 'win32' ? 'ollama.exe' : 'ollama')
    if (!existsSync(extractedBinaryPath)) {
      throw new Error(`Contained Ollama archive did not unpack a launchable binary at ${extractedBinaryPath}.`)
    }

    await rm(vendorRoot, { recursive: true, force: true })
    await ensureDirectory(vendorRoot)
    await runProcess('ditto', ['--clone', unpackRoot, vendorRoot], {
      env: getShellEnv(),
      timeoutMs: 300_000,
    })
    await clearMacLaunchMetadata(vendorRoot)

    await symlinkOrCopyToolBinary(bundledBinaryPath, localBinaryPath)
    appendTaskLog(task, `Contained Ollama linked at ${localBinaryPath}.`)
    return localBinaryPath
  } finally {
    await rm(downloadRoot, { recursive: true, force: true }).catch(() => {})
  }
}

async function ensureContainedAITooling(config, repoPath, task) {
  await ensureDirectory(getLocalBinRoot(repoPath))

  if (config.installRoachClaw === false) {
    appendTaskLog(task, 'Skipping contained RoachClaw tooling because this install has RoachClaw disabled.')
    return
  }

  await ensureContainedOllama(repoPath, task)

  const localOpenClawBinaryPath = getLocalToolBinaryPath('openclaw', repoPath)
  const stagedOpenClawBinaryPath = path.join(
    repoPath,
    'runtime',
    'vendor',
    'openclaw',
    'node_modules',
    '.bin',
    process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw'
  )

  if (existsSync(stagedOpenClawBinaryPath)) {
    await symlinkOrCopyToolBinary(stagedOpenClawBinaryPath, localOpenClawBinaryPath)
    appendTaskLog(task, 'Contained OpenClaw linked from the staged RoachNet payload.')
    return
  }

  appendTaskLog(
    task,
    'Deferring heavy OpenClaw hydration until after first launch so setup can finish fast on a clean machine.'
  )
}

function createTask(config) {
  return {
    id: hashString(`${Date.now()}-${config.installPath}-${Math.random()}`).slice(0, 10),
    status: 'running',
    phase: 'Preparing',
    startedAt: new Date().toISOString(),
    finishedAt: null,
    error: null,
    result: null,
    config,
    logs: [],
  }
}

function appendTaskLog(task, message) {
  task.logs.push(`[${new Date().toISOString()}] ${message}`)

  if (task.logs.length > TASK_LOG_LIMIT) {
    task.logs.splice(0, task.logs.length - TASK_LOG_LIMIT)
  }
}

async function ensureDirectory(directoryPath) {
  mkdirSync(directoryPath, { recursive: true })
}

async function ensureRequiredDependencies(config, task, packageManager, dependencies) {
  const requiredIds = getRequiredDependencyIds(config)
  let activeDependencies = applyDependencyRequirements(dependencies, config)
  const managedIds = getManagedDependencyIds(config, activeDependencies)

  if (!managedIds.length) {
    appendTaskLog(
      task,
      'RoachNet Setup is using the contained install lane. No global package manager installs will be attempted.'
    )
  }

  for (const dependencyId of managedIds) {
    const dependency = activeDependencies[dependencyId]
    if (dependency?.available) {
      appendTaskLog(
        task,
        `${dependency.label} is already available${dependency.version ? ` (${dependency.version})` : ''}.`
      )
      continue
    }

    throw new Error(
      `${dependency.label} is required for this source mode, but RoachNet Setup no longer performs global installs through ${packageManager.label}. Switch to the bundled install lane or install ${dependency.label} yourself first.`
    )
  }

  if (config.installRoachClaw !== false) {
    appendTaskLog(
      task,
      'RoachClaw defaults to contained Ollama and OpenClaw lanes managed inside RoachNet. Existing host installs stay optional and can be imported later.'
    )
  }
}

async function ensureDockerReady(task) {
  await startRoachNetContainerRuntime({
    commandExists,
    detectRuntime: () => detectContainerRuntime(),
    runProcess,
    runShell,
    env: getShellEnv(),
    timeoutMs: DOCKER_BOOT_TIMEOUT_MS,
    log(message) {
      appendTaskLog(task, message)
    },
  })
}

function shouldIncludeBundledSourcePath(relativePath) {
  if (!relativePath || relativePath === '') {
    return true
  }

  const normalizedPath = relativePath.split(path.sep).join('/')
  const segments = normalizedPath.split('/')
  const topLevel = segments[0]

  if (
    [
      '.git',
      'node_modules',
      '.native',
      'release',
      'dist',
      'desktop-dist',
      'setup-dist',
    ].includes(topLevel)
  ) {
    return false
  }

  if (
    normalizedPath.startsWith('native/macos/.build/') ||
    normalizedPath.startsWith('native/macos/.cache/') ||
    normalizedPath.startsWith('native/macos/dist/') ||
    normalizedPath.startsWith('native/linux/target/') ||
    normalizedPath.startsWith('native/windows/bin/') ||
    normalizedPath.startsWith('native/windows/obj/')
  ) {
    return false
  }

  if (
    normalizedPath === 'admin/node_modules' ||
    normalizedPath === 'admin/storage' ||
    normalizedPath.startsWith('admin/node_modules/') ||
    normalizedPath.startsWith('admin/storage/') ||
    normalizedPath.startsWith('installer/node_modules/') ||
    normalizedPath.includes('/node_modules_node') ||
    normalizedPath.includes('/storage/logs/') ||
    normalizedPath.includes('/storage/tmp/')
  ) {
    return false
  }

  if (
    normalizedPath === 'admin/.env' ||
    normalizedPath === '.DS_Store' ||
    normalizedPath.endsWith('/.DS_Store') ||
    normalizedPath.endsWith('.zim')
  ) {
    return false
  }

  return true
}

async function ensureRepository(config, repoPath, task) {
  await ensureDirectory(path.dirname(repoPath))

  if (
    (config.sourceMode === 'current-workspace' || config.sourceMode === 'bundled') &&
    repoPath === repoRoot
  ) {
    appendTaskLog(task, 'Using the current RoachNet workspace as the installation source.')
    return
  }

  const gitDirectoryPath = path.join(repoPath, '.git')
  const hasGitCheckout = existsSync(gitDirectoryPath)

  if (!existsSync(repoPath) || !hasGitCheckout) {
    if (existsSync(repoPath)) {
      const entries = await readdir(repoPath)
      if (entries.length > 0 && !hasGitCheckout) {
        throw new Error(
          `Install path ${repoPath} already exists and is not an empty git checkout. Choose an empty folder or an existing RoachNet checkout.`
        )
      }
    }

    if (config.sourceMode === 'current-workspace' || config.sourceMode === 'bundled') {
      appendTaskLog(task, `Copying bundled RoachNet source into ${repoPath}...`)
      await cp(repoRoot, repoPath, {
        recursive: true,
        force: true,
        filter(source) {
          const relativePath = path.relative(repoRoot, source)
          return shouldIncludeBundledSourcePath(relativePath)
        },
      })
      return
    }

    appendTaskLog(task, `Cloning RoachNet into ${repoPath}...`)
    await runProcess('git', ['clone', '--branch', config.sourceRef.trim(), config.sourceRepoUrl.trim(), repoPath], {
      env: getShellEnv(),
      cwd: path.dirname(repoPath),
    })
    return
  }

  appendTaskLog(task, 'Existing RoachNet checkout detected. Fetching the latest source...')
  await runProcess('git', ['fetch', '--all', '--tags', '--prune'], {
    cwd: repoPath,
    env: getShellEnv(),
  })

  await runProcess('git', ['checkout', config.sourceRef.trim()], {
    cwd: repoPath,
    env: getShellEnv(),
  })

  await runProcess('git', ['pull', '--ff-only', 'origin', config.sourceRef.trim()], {
    cwd: repoPath,
    env: getShellEnv(),
  })
}

async function smokeTestInstalledRuntime(config, envValues, task) {
  const nodeBinary = resolveInstalledAppNodeBinary(config)
  const launcherPath = path.join(config.installPath, 'scripts', 'run-roachnet.mjs')
  const healthUrl = new URL('/api/health', envValues.URL).toString()
  const storagePath = normalizeInputPath(config.storagePath || envValues.NOMAD_STORAGE_PATH || path.join(config.installPath, 'storage'))
  const runtimeStateRoot = normalizeInputPath(path.join(storagePath, 'state', 'runtime-state'))
  const localBinPath = normalizeInputPath(path.join(config.installPath, 'bin'))
  const openClawWorkspacePath = normalizeInputPath(
    envValues.OPENCLAW_WORKSPACE_PATH || path.join(storagePath, 'openclaw')
  )
  const ollamaModelsPath = normalizeInputPath(
    envValues.OLLAMA_MODELS || path.join(storagePath, 'ollama')
  )
  const installProfile = config.installProfile?.trim() || 'setup-app'
  const containerlessMode = config.useDockerContainerization ? '0' : '1'
  const launchEnv = {
    ...getShellEnv(),
    NOMAD_STORAGE_PATH: storagePath,
    OPENCLAW_WORKSPACE_PATH: openClawWorkspacePath,
    OLLAMA_MODELS: ollamaModelsPath,
    OLLAMA_BASE_URL: envValues.OLLAMA_BASE_URL || 'http://127.0.0.1:36434',
    OPENCLAW_BASE_URL: envValues.OPENCLAW_BASE_URL || 'http://127.0.0.1:13001',
    ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
    ROACHNET_LOCAL_BIN_PATH: localBinPath,
    ROACHNET_NODE_BINARY: nodeBinary,
    ROACHNET_NPM_BINARY: getPreferredNpmBinary(nodeBinary),
    ROACHNET_INSTALL_PROFILE: installProfile,
    ROACHNET_BOOTSTRAP_PENDING: config.bootstrapPending ? '1' : '0',
    ROACHNET_CONTAINERLESS_MODE: containerlessMode,
    ROACHNET_DISABLE_QUEUE: containerlessMode === '1' ? '1' : '0',
    ROACHNET_ROACHCLAW_DEFAULT_MODEL:
      config.roachClawDefaultModel?.trim() || DEFAULT_ROACHCLAW_MODEL,
    ROACHNET_INSTALLER_CONFIG_PATH: getInstallerConfigPath(),
    ROACHNET_NO_BROWSER: '1',
  }

  if (!existsSync(launcherPath)) {
    throw new Error(`Missing RoachNet launcher at ${launcherPath}.`)
  }

  appendTaskLog(task, 'Smoke testing the contained runtime before finalizing the install...')

  let launcherChild = null
  let launcherStdout = ''
  let launcherStderr = ''
  let launcherExitCode = null
  const runtimeLogsPath = path.join(storagePath, 'logs')
  const launcherLogPath = path.join(runtimeLogsPath, 'roachnet-launcher-debug.log')
  const serverLogPath = path.join(runtimeLogsPath, 'roachnet-server.log')

  try {
    launcherChild = spawn(nodeBinary, [launcherPath], {
      cwd: config.installPath,
      env: launchEnv,
    })

    launcherChild.stdout?.on('data', (chunk) => {
      launcherStdout += chunk.toString()
    })
    launcherChild.stderr?.on('data', (chunk) => {
      launcherStderr += chunk.toString()
    })

    launcherChild.once('error', (error) => {
      launcherStderr += `${error?.message || String(error)}\n`
    })

    try {
      await waitForHttpOk(healthUrl, PORT_WAIT_TIMEOUT_MS + 120_000)
    } catch (error) {
      const diagnostics = [launcherStderr.trim(), launcherStdout.trim()]

      if (existsSync(launcherLogPath)) {
        diagnostics.push(`launcher debug log:\n${readFileSync(launcherLogPath, 'utf8').trim()}`)
      }

      if (existsSync(serverLogPath)) {
        diagnostics.push(`server log:\n${readFileSync(serverLogPath, 'utf8').trim()}`)
      }

      throw new Error(
        [
          error.message,
          ...diagnostics.filter(Boolean),
        ].join('\n\n')
      )
    }
    appendTaskLog(task, `Contained runtime answered ${healthUrl}.`)

    // The runtime launcher is expected to stay alive once the health endpoint is up.
    // We only treat an early non-zero exit as a smoke-test failure.
    launcherExitCode = await waitForChildExit(launcherChild, 3_000)

    if (launcherExitCode !== null && launcherExitCode !== 0) {
      throw new Error(
        `Contained runtime launcher exited with code ${launcherExitCode} after ${healthUrl} answered successfully.\n${
          launcherStderr.trim() || launcherStdout.trim()
        }`
      )
    }
  } finally {
    await runProcess(nodeBinary, [launcherPath, '--stop'], {
      cwd: config.installPath,
      env: launchEnv,
      timeoutMs: 30_000,
    }).catch(() => {})

    const exitCode = await waitForChildExit(launcherChild, 10_000)
    if (exitCode === null && launcherChild) {
      launcherChild.kill('SIGKILL')
    }
  }
}

function buildManagementCompose({
  installPath,
  appPort,
  dbUser,
  dbPassword,
  dbRootPassword,
  appKey,
  logLevel,
  publicUrl,
  storagePath,
  openClawWorkspacePath,
  ollamaBaseUrl,
  openClawBaseUrl,
}) {
  const runtimeRoot = toComposePath(path.join(installPath, 'runtime'))
  const storageRoot = toComposePath(storagePath)
  const openClawWorkspaceRoot = toComposePath(openClawWorkspacePath)
  const appBindPort = Number(appPort)
  const publicBaseUrl = publicUrl.replace(/"/g, '\\"')
  const resolvedOllamaBaseUrl = ollamaBaseUrl.replace(/"/g, '\\"')
  const resolvedOpenClawBaseUrl = openClawBaseUrl.replace(/"/g, '\\"')
  const resolvedLogLevel = logLevel.replace(/"/g, '\\"')
  const resolvedDbUser = dbUser.replace(/"/g, '\\"')
  const resolvedDbPassword = dbPassword.replace(/"/g, '\\"')
  const resolvedDbRootPassword = dbRootPassword.replace(/"/g, '\\"')
  const resolvedAppKey = appKey.replace(/"/g, '\\"')

  return `services:
  admin:
    build:
      context: ..
      dockerfile: Dockerfile
    image: roachnet-local-admin
    container_name: roachnet_admin_${hashString(installPath).slice(0, 8)}
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "127.0.0.1:${appBindPort}:8080"
    volumes:
      - "${storageRoot}:/app/storage"
      - "/var/run/docker.sock:/var/run/docker.sock"
    environment:
      NODE_ENV: production
      PORT: "8080"
      HOST: "0.0.0.0"
      URL: "${publicBaseUrl}"
      LOG_LEVEL: "${resolvedLogLevel}"
      APP_KEY: "${resolvedAppKey}"
      DB_HOST: mysql
      DB_PORT: "3306"
      DB_DATABASE: nomad
      DB_USER: "${resolvedDbUser}"
      DB_PASSWORD: "${resolvedDbPassword}"
      DB_SSL: "false"
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      NOMAD_STORAGE_PATH: /app/storage
      OPENCLAW_WORKSPACE_PATH: "${openClawWorkspaceRoot}"
      OLLAMA_BASE_URL: "http://ollama:11434"
      OPENCLAW_BASE_URL: "${resolvedOpenClawBaseUrl}"
      ROACHNET_DB_ROOT_PASSWORD: "${resolvedDbRootPassword}"
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
      ollama:
        condition: service_started
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8080/api/health"]
      interval: 15s
      timeout: 10s
      retries: 20

  mysql:
    image: mysql:8.0
    container_name: roachnet_mysql_${hashString(installPath).slice(0, 8)}
    restart: unless-stopped
    command:
      - sh
      - -c
      - rm -f /var/run/mysqld/mysqld.sock.lock /var/run/mysqld/mysqlx.sock.lock /var/run/mysqld/mysqld.sock /var/run/mysqld/mysqlx.sock && exec docker-entrypoint.sh mysqld
    environment:
      MYSQL_ROOT_PASSWORD: "${resolvedDbRootPassword}"
      MYSQL_DATABASE: nomad
      MYSQL_USER: "${resolvedDbUser}"
      MYSQL_PASSWORD: "${resolvedDbPassword}"
    tmpfs:
      - /var/run/mysqld
    volumes:
      - "${runtimeRoot}/mysql:/var/lib/mysql"
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -p${resolvedDbRootPassword}"]
      interval: 15s
      timeout: 10s
      retries: 20

  redis:
    image: redis:7-alpine
    container_name: roachnet_redis_${hashString(installPath).slice(0, 8)}
    restart: unless-stopped
    ports:
      - "127.0.0.1:36379:6379"
    volumes:
      - "${runtimeRoot}/redis:/data"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 15s
      timeout: 10s
      retries: 20

  qdrant:
    image: qdrant/qdrant:v1.16
    container_name: roachnet_qdrant_${hashString(installPath).slice(0, 8)}
    restart: unless-stopped
    ports:
      - "127.0.0.1:36333:6333"
    volumes:
      - "${runtimeRoot}/qdrant:/qdrant/storage"

  ollama:
    image: ollama/ollama:0.20.2
    container_name: roachnet_ollama_${hashString(installPath).slice(0, 8)}
    restart: unless-stopped
    ports:
      - "127.0.0.1:36434:11434"
    volumes:
      - "${storageRoot}/ollama:/root/.ollama"
`
}

async function resolveInstallPort(preferredValue, startPort, label, task, host = SERVER_HOST) {
  const preferredPort = Number(preferredValue || 0)

  if (preferredPort > 0) {
    if (await canBindPort(preferredPort, host)) {
      return preferredPort
    }

    const fallbackPort = await findAvailablePort(startPort, host)
    appendTaskLog(task, `${label} port ${preferredPort} is already in use. Using ${fallbackPort} instead.`)
    return fallbackPort
  }

  return findAvailablePort(startPort, host)
}

async function prepareEnvironmentFiles(config, repoPath, task) {
  const adminPath = path.join(repoPath, 'admin')
  const envExamplePath = path.join(adminPath, '.env.example')
  const envPath = path.join(adminPath, '.env')
  const managementComposePath = path.join(repoPath, 'ops', 'roachnet-management.compose.yml')

  if (!existsSync(envExamplePath)) {
    throw new Error(`Missing env template at ${envExamplePath}`)
  }

  const exampleValues = parseEnvFile(await readFile(envExamplePath, 'utf8'))
  const existingValues = existsSync(envPath) ? parseEnvFile(await readFile(envPath, 'utf8')) : {}

  await ensureDirectory(path.join(repoPath, 'ops'))
  await ensureDirectory(path.join(repoPath, 'runtime', 'mysql'))
  await ensureDirectory(path.join(repoPath, 'runtime', 'redis'))
  await ensureDirectory(path.join(repoPath, 'app'))
  await ensureDirectory(path.join(repoPath, 'bin'))

  const port = await resolveInstallPort(existingValues.PORT, 8080, 'Application', task)
  const containerlessMode = config.useDockerContainerization ? '0' : '1'
  const dbPassword = existingValues.DB_PASSWORD || randomSecret(16)
  const dbRootPassword = existingValues.ROACHNET_DB_ROOT_PASSWORD || randomSecret(16)
  const appKey = existingValues.APP_KEY || randomSecret(24)
  const host = existingValues.HOST || '127.0.0.1'
  const storagePath = normalizeInputPath(config.storagePath || existingValues.NOMAD_STORAGE_PATH || path.join(repoPath, 'storage'))
  const openClawWorkspacePath = normalizeInputPath(path.join(storagePath, 'openclaw'))
  const sqliteDbPath = normalizeInputPath(path.join(storagePath, 'state', 'roachnet.sqlite'))
  const localToolsPath = normalizeInputPath(path.join(repoPath, 'bin'))
  const installedAppPath = getCanonicalInstalledAppPath(repoPath)
  const embeddedNodeBinaryPath = normalizeInputPath(
    path.join(installedAppPath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node', 'bin', 'node')
  )
  const embeddedNpmBinaryPath = normalizeInputPath(
    path.join(installedAppPath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node', 'bin', 'npm')
  )
  const ollamaBaseUrl = config.installRoachClaw === false
    ? (existingValues.OLLAMA_BASE_URL || 'http://127.0.0.1:36434')
    : 'http://127.0.0.1:36434'
  const openClawBaseUrl = config.installRoachClaw === false
    ? (existingValues.OPENCLAW_BASE_URL || 'http://127.0.0.1:13001')
    : 'http://127.0.0.1:13001'
  const ollamaModelsPath = normalizeInputPath(path.join(storagePath, 'ollama'))

  await ensureDirectory(storagePath)
  await ensureDirectory(openClawWorkspacePath)
  await ensureDirectory(ollamaModelsPath)
  await ensureDirectory(path.dirname(sqliteDbPath))

  const envValues = {
    ...exampleValues,
    ...existingValues,
    PORT: port,
    HOST: host,
    URL: resolveInstallBaseUrl(existingValues.URL, host, port),
    LOG_LEVEL: existingValues.LOG_LEVEL || 'info',
    APP_KEY: appKey,
    NODE_ENV: existingValues.NODE_ENV || 'production',
    DB_CONNECTION: containerlessMode === '1' ? 'sqlite' : 'mysql',
    DB_HOST: existingValues.DB_HOST || '127.0.0.1',
    DB_PORT: existingValues.DB_PORT || 3306,
    DB_USER: existingValues.DB_USER || 'nomad_user',
    DB_DATABASE: existingValues.DB_DATABASE || 'nomad',
    DB_PASSWORD: dbPassword,
    DB_SSL: existingValues.DB_SSL || 'false',
    SQLITE_DB_PATH: sqliteDbPath,
    REDIS_HOST: existingValues.REDIS_HOST || '127.0.0.1',
    REDIS_PORT: existingValues.REDIS_PORT || 6379,
    NOMAD_STORAGE_PATH: storagePath,
    OLLAMA_BASE_URL: ollamaBaseUrl,
    OLLAMA_MODELS: ollamaModelsPath,
    OPENCLAW_BASE_URL: openClawBaseUrl,
    OPENCLAW_WORKSPACE_PATH: openClawWorkspacePath,
    ROACHNET_LOCAL_BIN_PATH: localToolsPath,
    ROACHNET_NODE_BINARY: embeddedNodeBinaryPath,
    ROACHNET_NPM_BINARY: embeddedNpmBinaryPath,
    ROACHNET_CONTAINERLESS_MODE: containerlessMode,
    ROACHNET_DISABLE_QUEUE: containerlessMode === '1' ? '1' : '0',
    ROACHNET_DISABLE_TRANSMIT: existingValues.ROACHNET_DISABLE_TRANSMIT || '1',
    ROACHNET_DB_ROOT_PASSWORD: dbRootPassword,
  }

  writeFileSync(envPath, serializeEnvFile(envValues), 'utf8')
  writeFileSync(
    managementComposePath,
    buildManagementCompose({
      installPath: repoPath,
      appPort: port,
      dbUser: envValues.DB_USER,
      dbPassword,
      dbRootPassword,
      appKey,
      logLevel: envValues.LOG_LEVEL,
      publicUrl: envValues.URL,
      storagePath,
      openClawWorkspacePath,
      ollamaBaseUrl,
      openClawBaseUrl,
    }),
    'utf8'
  )

  appendTaskLog(task, `Prepared RoachNet env file at ${envPath}.`)
  appendTaskLog(task, `Prepared Docker management file at ${managementComposePath}.`)
  appendTaskLog(task, `RoachNet storage will live inside ${storagePath}.`)
  appendTaskLog(
    task,
    containerlessMode === '1'
      ? 'The first boot will use the contained local runtime lane instead of installing global dependencies.'
      : 'Docker containerization is enabled for the support-services lane. RoachNet will still keep its payload inside the install root.'
  )

  return {
    envValues,
    adminPath,
    envPath,
    managementComposePath,
  }
}

async function startSupportServices(repoPath, managementComposePath, task) {
  appendTaskLog(task, 'Starting RoachNet support services through the integrated container runtime...')
  await composeUpRoachNetServices({
    composeFiles: [managementComposePath],
    cwd: repoPath,
    installPath: repoPath,
    runProcess,
    env: getShellEnv(),
    waitTimeoutMs: DOCKER_BOOT_TIMEOUT_MS,
    services: ['mysql', 'redis'],
    onStdout(text) {
      for (const line of text.split(/\r?\n/).filter(Boolean)) {
        appendTaskLog(task, line)
      }
    },
    onStderr(text) {
      for (const line of text.split(/\r?\n/).filter(Boolean)) {
        appendTaskLog(task, line)
      }
    },
  })
}

async function runAdminSetup(repoPath, managementComposePath, task) {
  const logLines = (text) => {
    for (const line of text.split(/\r?\n/).filter(Boolean)) {
      appendTaskLog(task, line)
    }
  }

  appendTaskLog(task, 'Building and starting the containerized RoachNet runtime...')
  await composeUpRoachNetServices({
    composeFiles: [managementComposePath],
    cwd: repoPath,
    installPath: repoPath,
    runProcess,
    env: getShellEnv(),
    waitTimeoutMs: DOCKER_BOOT_TIMEOUT_MS,
    services: ['admin'],
    build: true,
    onStdout: logLines,
    onStderr: logLines,
  })
}

function openBrowser(url) {
  if (process.env.ROACHNET_SETUP_NO_BROWSER === '1') {
    return
  }

  if (process.platform === 'darwin') {
    spawn('open', [url], { detached: true, stdio: 'ignore' }).unref()
    return
  }

  if (process.platform === 'win32') {
    spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore' }).unref()
    return
  }

  spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref()
}

async function launchInstalledRoachNet(repoPath, openPath, installedAppPath) {
  const nodeBinary = resolveInstalledAppNodeBinary(repoPath, installedAppPath)
  const persistedConfig = getDefaultConfig(loadPersistedInstallerConfig())
  const envPath = path.join(repoPath, 'admin', '.env')
  const envValues = existsSync(envPath) ? parseEnvFile(readFileSync(envPath, 'utf8')) : {}
  const storagePath = normalizeInputPath(
    persistedConfig.storagePath || envValues.NOMAD_STORAGE_PATH || path.join(repoPath, 'storage')
  )
  const installProfile = persistedConfig.installProfile?.trim() || 'standard'
  const localBinPath = normalizeInputPath(path.join(repoPath, 'bin'))
  const runtimeStateRoot = normalizeInputPath(path.join(storagePath, 'state', 'runtime-state'))
  const openClawWorkspacePath = normalizeInputPath(
    envValues.OPENCLAW_WORKSPACE_PATH || path.join(storagePath, 'openclaw')
  )
  const ollamaModelsPath = normalizeInputPath(
    envValues.OLLAMA_MODELS || path.join(storagePath, 'ollama')
  )
  const embeddedNpmBinaryPath = normalizeInputPath(
    path.join(installedAppPath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node', 'bin', 'npm')
  )
  const containerlessMode = persistedConfig.useDockerContainerization === false ? '1' : '0'
  spawn(nodeBinary, [path.join(repoPath, 'scripts', 'run-roachnet.mjs')], {
    cwd: repoPath,
    detached: true,
    stdio: 'ignore',
    env: {
      ...getShellEnv(),
      NOMAD_STORAGE_PATH: storagePath,
      OPENCLAW_WORKSPACE_PATH: openClawWorkspacePath,
      OLLAMA_MODELS: ollamaModelsPath,
      OLLAMA_BASE_URL: envValues.OLLAMA_BASE_URL || 'http://127.0.0.1:36434',
      OPENCLAW_BASE_URL: envValues.OPENCLAW_BASE_URL || 'http://127.0.0.1:13001',
      ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
      ROACHNET_LOCAL_BIN_PATH: localBinPath,
      ROACHNET_NODE_BINARY: nodeBinary,
      ROACHNET_NPM_BINARY: embeddedNpmBinaryPath,
      ROACHNET_INSTALL_PROFILE: installProfile,
      ROACHNET_BOOTSTRAP_PENDING: persistedConfig.bootstrapPending ? '1' : '0',
      ROACHNET_CONTAINERLESS_MODE: containerlessMode,
      ROACHNET_DISABLE_QUEUE: containerlessMode === '1' ? '1' : '0',
      ROACHNET_ROACHCLAW_DEFAULT_MODEL:
        persistedConfig.roachClawDefaultModel?.trim() || DEFAULT_ROACHCLAW_MODEL,
      ROACHNET_INSTALLER_CONFIG_PATH: getInstallerConfigPath(),
      ROACHNET_OPEN_PATH: openPath,
      ROACHNET_NO_BROWSER: process.env.ROACHNET_NO_BROWSER || '0',
    },
  }).unref()
}

async function runInstallWorkflow(config) {
  const finalInstallPath = normalizeInputPath(config.installPath)
  const finalInstalledAppPath = getCanonicalInstalledAppPath(finalInstallPath)
  const finalStoragePath = normalizeInputPath(
    config.storagePath || path.join(finalInstallPath, 'storage')
  )
  const normalizedConfig = {
    ...config,
    installPath: finalInstallPath,
    installedAppPath: finalInstalledAppPath,
    storagePath: finalStoragePath,
    sourceRepoUrl: config.sourceRepoUrl?.trim() || DEFAULT_SOURCE_REPO_URL,
    sourceRef: config.sourceRef?.trim() || DEFAULT_SOURCE_REF,
    installRoachClaw: config.installRoachClaw !== false,
    roachClawDefaultModel: config.roachClawDefaultModel?.trim() || DEFAULT_ROACHCLAW_MODEL,
    installOptionalOllama: config.installRoachClaw !== false,
    installOptionalOpenClaw: config.installRoachClaw !== false,
    releaseChannel: ['stable', 'beta', 'alpha'].includes(config.releaseChannel)
      ? config.releaseChannel
      : 'stable',
    updateBaseUrl: config.updateBaseUrl?.trim().replace(/\/+$/, '') || '',
    autoInstallDependencies: false,
    useDockerContainerization: Boolean(config.useDockerContainerization),
  }
  const task = createTask(normalizedConfig)
  runtimeState.task = task
  const stagingInstallPath = await mkdtemp(
    path.join(path.dirname(finalInstallPath), `${path.basename(finalInstallPath)}.staging-`)
  )
  const stagedConfig = {
    ...normalizedConfig,
    installPath: stagingInstallPath,
    installedAppPath: remapPathWithinInstallRoot(
      normalizedConfig.installedAppPath,
      finalInstallPath,
      stagingInstallPath
    ),
    storagePath: remapPathWithinInstallRoot(
      normalizedConfig.storagePath,
      finalInstallPath,
      stagingInstallPath
    ),
  }

  const setPhase = (phase) => {
    task.phase = phase
    appendTaskLog(task, `Phase: ${phase}`)
  }

  try {
    saveInstallerConfig(normalizedConfig)

    setPhase('Inspecting system')
    const containerRuntime = await detectContainerRuntime()
    const packageManager = await detectPackageManager()
    const dependencies = applyDependencyRequirements(
      await detectDependencies({ containerRuntime }),
      normalizedConfig
    )

    appendTaskLog(task, `Detected ${describePlatform().osLabel} ${process.arch}.`)
    appendTaskLog(task, `Detected package manager: ${packageManager.label}.`)

    setPhase('Validating contained install lane')
    await ensureRequiredDependencies(normalizedConfig, task, packageManager, dependencies)
    await ensureInstallVolumeHeadroom(normalizedConfig, task)

    setPhase('Staging RoachNet')
    await ensureRepository(stagedConfig, stagedConfig.installPath, task)

    setPhase('Installing contained AI tooling')
    await ensureContainedAITooling(stagedConfig, stagedConfig.installPath, task)

    setPhase('Preparing contained runtime')
    const prepared = await prepareEnvironmentFiles(stagedConfig, stagedConfig.installPath, task)

    setPhase('Installing native desktop app')
    await installNativeDesktopApp(stagedConfig, task)

    setPhase('Verifying contained runtime')
    await smokeTestInstalledRuntime(stagedConfig, prepared.envValues, task)

    setPhase('Finalizing install')
    await finalizeInstallRoot(stagedConfig.installPath, normalizedConfig.installPath, task)
    const finalized = await prepareEnvironmentFiles(normalizedConfig, normalizedConfig.installPath, task)

    setPhase('Arming RoachTail local alias')
    await provisionRoachTailLocalHostname(task)

    if (normalizedConfig.autoLaunch) {
      setPhase('Launching RoachNet')
      await launchNativeDesktopApp(normalizedConfig.installedAppPath)
      appendTaskLog(task, `RoachNet desktop app launched from ${normalizedConfig.installedAppPath}`)
      await requestSetupAppQuit()
    }

    task.status = 'completed'
    task.finishedAt = new Date().toISOString()
    task.result = {
      installPath: normalizedConfig.installPath,
      appPath: normalizedConfig.installedAppPath,
      url: finalized.envValues.URL,
      managementComposePath: finalized.managementComposePath,
    }
    saveInstallerConfig({
      ...normalizedConfig,
      installedAppPath: normalizedConfig.installedAppPath,
      installOptionalOllama: normalizedConfig.installRoachClaw !== false,
      installOptionalOpenClaw: normalizedConfig.installRoachClaw !== false,
      setupCompletedAt: task.finishedAt,
      pendingLaunchIntro: true,
      pendingRoachClawSetup: normalizedConfig.installRoachClaw !== false,
      roachClawOnboardingCompletedAt: null,
      introCompletedAt: null,
      lastLaunchUrl: task.result.url,
      preferredShell: 'native',
    })
    appendTaskLog(task, 'RoachNet setup completed successfully.')
  } catch (error) {
    task.status = 'failed'
    task.finishedAt = new Date().toISOString()
    task.error = sanitizeInstallerErrorMessage(error, normalizedConfig)
    appendTaskLog(task, `Setup failed: ${task.error}`)
    if (process.env.ROACHNET_SMOKE_KEEP_TEMP === '1' || process.env.ROACHNET_SETUP_KEEP_STAGED_FAILURE === '1') {
      appendTaskLog(task, `Preserving staged install at ${stagingInstallPath} for debugging.`)
    } else {
      await rm(stagingInstallPath, { recursive: true, force: true })
      appendTaskLog(task, 'Removed the staged install so this Mac can retry setup cleanly.')
    }
  } finally {
    invalidateInstallerDiagnosticsCache()
    runtimeState.lastCompletedTask = task
    runtimeState.task = null
  }

  return task
}

async function getInstallerState(searchParams = new URLSearchParams()) {
  const mergedConfig = getDefaultConfig({
    installPath: searchParams.get('installPath') || undefined,
    installedAppPath: searchParams.get('installedAppPath') || undefined,
    sourceMode: searchParams.get('sourceMode') || undefined,
    sourceRepoUrl: searchParams.get('sourceRepoUrl') || undefined,
    sourceRef: searchParams.get('sourceRef') || undefined,
    autoInstallDependencies:
      searchParams.get('autoInstallDependencies') === null
        ? undefined
        : searchParams.get('autoInstallDependencies') === 'true',
    useDockerContainerization:
      searchParams.get('useDockerContainerization') === null
        ? undefined
        : searchParams.get('useDockerContainerization') === 'true',
    installRoachClaw:
      searchParams.get('installRoachClaw') === null
        ? undefined
        : searchParams.get('installRoachClaw') === 'true',
    roachClawDefaultModel: searchParams.get('roachClawDefaultModel') || undefined,
    autoLaunch:
      searchParams.get('autoLaunch') === null
        ? undefined
        : searchParams.get('autoLaunch') === 'true',
    releaseChannel: searchParams.get('releaseChannel') || undefined,
    updateBaseUrl: searchParams.get('updateBaseUrl') || undefined,
    autoCheckUpdates:
      searchParams.get('autoCheckUpdates') === null
        ? undefined
        : searchParams.get('autoCheckUpdates') === 'true',
    launchAtLogin:
      searchParams.get('launchAtLogin') === null
        ? undefined
        : searchParams.get('launchAtLogin') === 'true',
    dryRun:
      searchParams.get('dryRun') === null ? undefined : searchParams.get('dryRun') === 'true',
  })

  const now = Date.now()
  let cachedDiagnostics = runtimeState.diagnosticsCache.value

  if (!cachedDiagnostics) {
    cachedDiagnostics = buildPendingDiagnostics(mergedConfig)
    runtimeState.diagnosticsCache.value = cachedDiagnostics
    runtimeState.diagnosticsCache.expiresAt = 0
    queueInstallerDiagnosticsRefresh(mergedConfig)
  } else if (runtimeState.diagnosticsCache.expiresAt <= now && !runtimeState.diagnosticsCache.refreshPromise) {
    queueInstallerDiagnosticsRefresh(mergedConfig)
  }

  const packageManager = cachedDiagnostics.packageManager
  const containerRuntime = cachedDiagnostics.containerRuntime
  const dependencies = applyDependencyRequirements(cachedDiagnostics.dependencies, mergedConfig)
  const installPath = normalizeInputPath(mergedConfig.installPath)
  const installedAppPath = normalizeInputPath(
    mergedConfig.installedAppPath || getDefaultInstalledAppPath(installPath)
  )
  const installLooksReady =
    existsSync(path.join(installPath, 'admin', 'package.json')) &&
    existsSync(path.join(installPath, 'scripts', 'run-roachnet.mjs'))

  const dependencyList = Object.values(dependencies).map((dependency) => ({
    ...dependency,
    installCommand: getDependencyInstallCommand(packageManager.id, dependency.id),
    notes: [
      getDependencyNotes(packageManager.id, dependency.id),
      dependency.needsUpdate && dependency.minimumVersion && dependency.version
        ? `${dependency.label} ${dependency.version} can be updated to ${dependency.minimumVersion}.`
        : null,
      dependency.needsUpdate && dependency.minimumVersion && !dependency.version
        ? `${dependency.label} needs an update to satisfy ${dependency.minimumVersion}.`
        : null,
      dependency.needsUpdate && !dependency.minimumVersion
        ? `A newer ${dependency.label} release is available from the detected package source.`
        : null,
      dependency.id === 'docker' && dependency.available && dependency.daemonRunning === false
        ? 'Docker is installed but the daemon is not running yet. RoachNet Setup can launch Docker Desktop automatically.'
        : null,
      dependency.bundled
        ? `${dependency.label} is currently satisfied by the bundled runtime inside RoachNet Setup.`
        : null,
    ]
      .filter(Boolean)
      .join(' '),
  }))

  return {
    system: {
      ...describePlatform(),
      packageManager,
      currentWorkspaceSourceAvailable: hasCurrentWorkspaceSource(),
    },
    config: mergedConfig,
    installPath,
    nativeApp: {
      installPath: installedAppPath,
      installed: existsSync(installedAppPath),
      kind: getLocalArtifactDescriptor(getCurrentAppVersion()).kind,
    },
    installLooksReady,
    containerRuntime: {
      available: Boolean(containerRuntime.dockerCliPath),
      ...containerRuntime,
      detectionPending: Boolean(containerRuntime.detectionPending),
      composeProjectName: getRoachNetComposeProjectName(installPath),
      docs: DOCKER_DOCS,
    },
    dependencies: dependencyList,
    activeTask: runtimeState.task,
    lastCompletedTask: runtimeState.lastCompletedTask,
    sourceModes: [
      {
        id: 'clone',
        label: 'Clone from GitHub',
        description: 'Download RoachNet into the chosen install folder from the configured git repository.',
      },
      {
        id: 'bundled',
        label: 'Install bundled RoachNet',
        description: 'Copy the RoachNet payload bundled with this installer into the chosen install folder.',
        available: hasCurrentWorkspaceSource(),
      },
      {
        id: 'current-workspace',
        label: 'Use current workspace',
        description: 'Advanced option: use the current local source tree as the installation source.',
        available: existsSync(path.join(repoRoot, '.git')) && hasCurrentWorkspaceSource(),
      },
    ],
  }
}

async function handleContainerRuntimeStartRequest(_request, response) {
  try {
    const runtime = await startRoachNetContainerRuntime({
      commandExists,
      detectRuntime: () =>
        detectRoachNetContainerRuntime({
          commandPath,
          commandExists,
          runProcess,
        }),
      runProcess,
      runShell,
      env: getShellEnv(),
    })

    sendJson(response, {
      ok: true,
      runtime,
    })
    invalidateInstallerDiagnosticsCache()
  } catch (error) {
    sendJson(response, { error: error.message }, 400)
  }
}

async function handleInstallRequest(request, response) {
  if (runtimeState.task?.status === 'running') {
    sendJson(
      response,
      {
        error: 'A setup task is already running. Wait for it to finish before starting another one.',
      },
      409
    )
    return
  }

  try {
    const payload = await parseJsonBody(request)
    const config = getDefaultConfig(payload)

    if (config.dryRun) {
      const previewTask = createTask(config)
      previewTask.status = 'completed'
      previewTask.finishedAt = new Date().toISOString()
      previewTask.result = {
        installPath: normalizeInputPath(config.installPath),
        appPath: normalizeInputPath(
          config.installedAppPath || getDefaultInstalledAppPath(config.installPath)
        ),
        note: 'Preview mode does not execute commands yet. Turn it off to run the real installation.',
      }
      appendTaskLog(previewTask, 'Preview mode is enabled. No commands were executed.')
      runtimeState.lastCompletedTask = previewTask
      sendJson(response, { ok: true, task: previewTask })
      return
    }

    runInstallWorkflow(config)
    sendJson(response, { ok: true })
  } catch (error) {
    sendJson(response, { error: error.message }, 400)
  }
}

async function handleConfigRequest(request, response) {
  try {
    const payload = await parseJsonBody(request)
    const config = getDefaultConfig(payload)
    saveInstallerConfig(config)
    invalidateInstallerDiagnosticsCache()
    sendJson(response, { ok: true, config })
  } catch (error) {
    sendJson(response, { error: error.message }, 400)
  }
}

async function handleLaunchRequest(request, response) {
  try {
    const payload = await parseJsonBody(request)
    const installPath = normalizeInputPath(payload.installPath || getDefaultInstallPath())
    const config = getDefaultConfig(payload)
    const installedAppPath = normalizeInputPath(
      payload.installedAppPath ||
        config.installedAppPath ||
        getDefaultInstalledAppPath(installPath)
    )

    if (existsSync(installedAppPath)) {
      saveInstallerConfig({
        ...config,
        installPath,
        installedAppPath,
        lastOpenedMode: 'app',
        preferredShell: 'native',
      })
      await launchNativeDesktopApp(installedAppPath)
      sendJson(response, { ok: true, launched: 'native-app', installedAppPath })
      return
    }

    if (!existsSync(path.join(installPath, 'scripts', 'run-roachnet.mjs'))) {
      sendJson(
        response,
        {
          error: `No RoachNet launcher was found in ${installPath}. Run setup first or choose a valid RoachNet install path.`,
        },
        400
      )
      return
    }

    saveInstallerConfig({
      ...config,
      installPath,
      installedAppPath,
      lastOpenedMode: 'app',
      preferredShell: 'native',
    })
    await launchInstalledRoachNet(installPath, '/easy-setup', installedAppPath)
    sendJson(response, { ok: true })
  } catch (error) {
    sendJson(response, { error: error.message }, 400)
  }
}

async function requestHandler(request, response) {
  const requestUrl = new URL(request.url || '/', 'http://localhost')

  if (request.method === 'GET' && requestUrl.pathname === '/api/state') {
    sendJson(response, await getInstallerState(requestUrl.searchParams))
    return
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/install') {
    await handleInstallRequest(request, response)
    return
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/container-runtime/start') {
    await handleContainerRuntimeStartRequest(request, response)
    return
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/config') {
    await handleConfigRequest(request, response)
    return
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/launch') {
    await handleLaunchRequest(request, response)
    return
  }

  if (request.method === 'GET') {
    if (requestUrl.pathname === '/roachnet-mark.png') {
      await serveStaticFile(response, path.join(repoRoot, 'admin', 'public', 'roachnet-mark.png'))
      return
    }

    const requestedPath =
      requestUrl.pathname === '/' ? 'index.html' : requestUrl.pathname.replace(/^\/+/, '')
    await serveStaticFile(response, path.join(uiRoot, requestedPath))
    return
  }

  sendText(response, 'Method not allowed', 405)
}

async function main() {
  if (!existsSync(path.join(uiRoot, 'index.html'))) {
    throw new Error(`Missing setup UI at ${uiRoot}`)
  }

  const server = http.createServer((request, response) => {
    requestHandler(request, response).catch((error) => {
      sendJson(response, { error: error.message }, 500)
    })
  })

  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(Number(process.env.ROACHNET_SETUP_PORT || 0), SERVER_HOST, () => {
      resolve()
    })
  })

  const address = server.address()
  if (typeof address !== 'object' || !address) {
    throw new Error('Failed to determine RoachNet Setup server address.')
  }

  const url = `http://${SERVER_HOST}:${address.port}`
  writeSetupReadyFile(url)
  console.log(`RoachNet Setup is available at ${url}`)
  console.log('Use this interface to choose an install path, bootstrap dependencies, and launch Easy Setup.')
  openBrowser(url)
}

main().catch((error) => {
  console.error(error.message)
  process.exitCode = 1
})
