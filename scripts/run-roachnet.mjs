#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { lookup } from 'node:dns/promises'
import { appendFileSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { cp, readFile } from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import {
  composeDownRoachNetServices,
  composeUpRoachNetServices,
  detectRoachNetContainerRuntime,
  getRoachNetComposeProjectName,
  startRoachNetContainerRuntime,
} from './lib/roachnet_container_runtime.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const adminDir = path.join(repoRoot, 'admin')
const buildDir = path.join(adminDir, 'build')
const envPath = path.join(adminDir, '.env')
const buildEntrypointPath = path.join(buildDir, 'bin', 'server.js')
const buildPackageJsonPath = path.join(buildDir, 'package.json')
const buildPackageLockPath = path.join(buildDir, 'package-lock.json')
const buildAssetManifestPath = path.join(buildDir, 'public', 'assets', '.vite', 'manifest.json')
const buildStampPath = path.join(buildDir, '.roachnet-build-stamp.json')
const managementComposePath = path.join(repoRoot, 'ops', 'roachnet-management.compose.yml')

const SERVER_BOOT_TIMEOUT_MS = 300_000
const BUILD_BOOT_TIMEOUT_MS = 300_000
const HEALTH_POLL_INTERVAL_MS = 1_500
const HEALTH_REQUEST_TIMEOUT_MS = 3_000
const EXITED_SERVER_HEALTH_GRACE_MS = 10_000
const EXISTING_RUNTIME_RECONNECT_GRACE_MS = 10_000
const BUILD_RUNTIME_METADATA_FILENAME = '.roachnet-runtime.json'
const BUILD_RUNTIME_DEPENDENCY_STAMP_FILENAME = '.roachnet-lock-hash'
const BUILD_RUNTIME_CODESIGN_STAMP_FILENAME = '.roachnet-codesign-stamp'
const BUILD_RUNTIME_CODESIGN_VERSION = '1'
const BUILD_RUNTIME_MYSQL_PORT = '33306'
const BUILD_RUNTIME_REDIS_PORT = '36379'
const BUILD_RUNTIME_QDRANT_PORT = '36333'
const BUILD_RUNTIME_OLLAMA_PORT = '36434'
const BUILD_RUNTIME_OPENCLAW_PORT = '13001'
const DEFAULT_COMPANION_HOST = '0.0.0.0'
const DEFAULT_COMPANION_PORT = '38111'
const DEFAULT_ROACHNET_LOCAL_HOSTNAME = 'RoachNet'
const MANAGED_PORT_FALLBACKS = ['8080', BUILD_RUNTIME_OLLAMA_PORT, BUILD_RUNTIME_OPENCLAW_PORT]
const MANAGED_RUNTIME_DB_USER = 'nomad_user'
const MANAGED_RUNTIME_SECRETS_FILENAME = 'roachnet-managed-runtime-secrets.json'
const MANAGED_RUNTIME_DB_DATABASE = 'nomad'
const LEGACY_MANAGED_RUNTIME_DB_PASSWORD = '7154b9bbb511df8d89c1e1417d8427e3'
const LEGACY_MANAGED_RUNTIME_DB_ROOT_PASSWORD = '00e17487a0231b35b6030087ecb9aaf5'
const MANAGED_COMPOSE_SERVICE_NAMES = new Set(['mysql', 'redis', 'qdrant', 'ollama'])

function getStorageLogsDir(envValues = process.env) {
  return path.join(normalizeStorageRoot(envValues?.NOMAD_STORAGE_PATH), 'logs')
}

function getServerLogPath(envValues = process.env) {
  return path.join(getStorageLogsDir(envValues), 'roachnet-server.log')
}

function getLauncherDebugLogPath(envValues = process.env) {
  return path.join(getStorageLogsDir(envValues), 'roachnet-launcher-debug.log')
}

function getRuntimeProcessInfoPath(envValues = process.env) {
  return path.join(getStorageLogsDir(envValues), 'roachnet-runtime-processes.json')
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

async function loadEnv() {
  if (!existsSync(envPath)) {
    throw new Error(`Missing environment file at ${envPath}`)
  }

  const raw = await readFile(envPath, 'utf8')
  return parseEnvFile(raw)
}

function isTruthyFlag(value) {
  return ['1', 'true', 'yes', 'on', 'enabled'].includes(String(value || '').trim().toLowerCase())
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

function getRoachNetLocalHostname(envValues = process.env) {
  return envValues.ROACHNET_LOCAL_HOSTNAME?.trim() || DEFAULT_ROACHNET_LOCAL_HOSTNAME
}

function getDisplayUrl(targetUrl, envValues = process.env) {
  const parsedUrl = targetUrl instanceof URL ? new URL(targetUrl.toString()) : new URL(String(targetUrl))
  if (!isLoopbackHost(parsedUrl.hostname)) {
    return parsedUrl
  }

  parsedUrl.hostname = getRoachNetLocalHostname(envValues)
  return parsedUrl
}

async function getPreferredPublicUrl(targetUrl, envValues = process.env) {
  const parsedUrl = targetUrl instanceof URL ? new URL(targetUrl.toString()) : new URL(String(targetUrl))
  const displayUrl = getDisplayUrl(parsedUrl, envValues)

  if (displayUrl.hostname === parsedUrl.hostname) {
    return parsedUrl
  }

  try {
    await lookup(displayUrl.hostname)
    return displayUrl
  } catch {
    return parsedUrl
  }
}

function getBaseUrl(envValues) {
  if (envValues.URL) {
    return new URL(envValues.URL)
  }

  const host = envValues.HOST || 'localhost'
  const port = envValues.PORT || '8080'
  return new URL(`http://${host}:${port}`)
}

function getRequestedOpenPath() {
  const requestedPath = process.env.ROACHNET_OPEN_PATH || '/home'
  return requestedPath.startsWith('/') ? requestedPath : `/${requestedPath}`
}

function getLocalBinRoot() {
  return process.env.ROACHNET_LOCAL_BIN_PATH?.trim() || path.join(repoRoot, 'bin')
}

function getLocalToolBinaryPath(toolName) {
  return path.join(getLocalBinRoot(), process.platform === 'win32' ? `${toolName}.cmd` : toolName)
}

function getPreferredNpmBinary() {
  const nodeBinary = getPreferredNodeBinary()
  const localNodeNpm = nodeBinary.includes(path.sep)
    ? path.join(path.dirname(nodeBinary), process.platform === 'win32' ? 'npm.cmd' : 'npm')
    : null
  const localBinNpm = getLocalToolBinaryPath('npm')
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/npm'

  return [process.env.ROACHNET_NPM_BINARY, localNodeNpm, localBinNpm, macHomebrewNode22, 'npm']
    .filter(Boolean)
    .find((candidate) => candidate === 'npm' || existsSync(candidate)) || 'npm'
}

function hashString(value) {
  return createHash('sha256').update(value).digest('hex')
}

function randomSecret(size = 24) {
  return randomBytes(size).toString('hex')
}

function collectBuildSignatureParts(currentPath, relativePath = '.') {
  const entries = readdirSync(currentPath, { withFileTypes: true })
  const parts = []

  for (const entry of entries) {
    const nextRelativePath = path.join(relativePath, entry.name)

    if (nextRelativePath === 'node_modules' || nextRelativePath === path.join('public', 'assets')) {
      continue
    }

    const fullPath = path.join(currentPath, entry.name)

    if (entry.isDirectory()) {
      parts.push(...collectBuildSignatureParts(fullPath, nextRelativePath))
      continue
    }

    if (!entry.isFile()) {
      continue
    }

    parts.push(`${nextRelativePath}\n${hashString(readFileSync(fullPath))}`)
  }

  return parts
}

function getLoopbackHealthUrls(baseUrl, envValues = process.env) {
  const urls = []
  const protocol = baseUrl.protocol
  const pathName = '/api/health'
  const hostCandidates = new Set()
  const portCandidates = new Set()
  const envHost = envValues.HOST?.trim() || ''
  const envPort = envValues.PORT?.trim() || ''

  const pushUrl = (candidate) => {
    const serialized = candidate.toString()
    if (!urls.some((url) => url.toString() === serialized)) {
      urls.push(candidate)
    }
  }

  pushUrl(new URL(pathName, baseUrl))

  if (isLoopbackHost(baseUrl.hostname) || isLoopbackHost(envHost)) {
    hostCandidates.add('localhost')
    hostCandidates.add('127.0.0.1')
    hostCandidates.add('[::1]')

    if (envHost && isLoopbackHost(envHost)) {
      hostCandidates.add(formatUrlHost(envHost))
    }

    if (baseUrl.port) {
      portCandidates.add(baseUrl.port)
    }

    if (envPort) {
      portCandidates.add(String(envPort))
    }

    for (const port of portCandidates) {
      for (const candidateHost of hostCandidates) {
        pushUrl(new URL(`${protocol}//${candidateHost}${port ? `:${port}` : ''}${pathName}`))
      }
    }
  }

  return urls
}

async function checkHealthOnce(urls) {
  for (const url of urls) {
    const abortController = new AbortController()
    const timeout = setTimeout(() => abortController.abort(), HEALTH_REQUEST_TIMEOUT_MS)

    try {
      const response = await fetch(url, {
        headers: { Accept: 'application/json' },
        signal: abortController.signal,
      })

      if (response.ok) {
        return url
      }
    } catch {
      // Server is still booting or another loopback host is in use.
    } finally {
      clearTimeout(timeout)
    }
  }

  return null
}

async function waitForHealth(urls, timeoutMs, options = {}) {
  const exitWhen = typeof options.exitWhen === 'function' ? options.exitWhen : null
  const exitGraceMs = Math.max(0, Number(options.exitGraceMs) || 0)
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    const healthyUrl = await checkHealthOnce(urls)
    if (healthyUrl) {
      return healthyUrl
    }

    if (exitWhen?.()) {
      const remainingMs = timeoutMs - (Date.now() - startedAt)
      if (exitGraceMs > 0 && remainingMs > 0) {
        return waitForHealth(urls, Math.min(exitGraceMs, remainingMs))
      }

      return null
    }

    await new Promise((resolve) => setTimeout(resolve, HEALTH_POLL_INTERVAL_MS))
  }

  return null
}

async function waitForHttpEndpoint(url, timeoutMs, accept = (response) => response.ok) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    const abortController = new AbortController()
    const timeout = setTimeout(() => abortController.abort(), HEALTH_REQUEST_TIMEOUT_MS)

    try {
      const response = await fetch(url, {
        headers: { Accept: 'application/json' },
        signal: abortController.signal,
      })

      if (accept(response)) {
        clearTimeout(timeout)
        return true
      }
    } catch {
      // Dependency is still booting.
    } finally {
      clearTimeout(timeout)
    }

    await new Promise((resolve) => setTimeout(resolve, HEALTH_POLL_INTERVAL_MS))
  }

  return false
}

function getPreferredNodeBinary() {
  const appEmbeddedNode = path.join(
    repoRoot,
    'app',
    'RoachNet.app',
    'Contents',
    'Resources',
    'EmbeddedRuntime',
    'node',
    'bin',
    'node'
  )
  const siblingEmbeddedNode = path.resolve(
    repoRoot,
    '..',
    'EmbeddedRuntime',
    'node',
    'bin',
    'node'
  )
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/node'
  return [
    process.env.ROACHNET_NODE_BINARY,
    appEmbeddedNode,
    siblingEmbeddedNode,
    macHomebrewNode22,
    process.execPath,
  ]
    .filter(Boolean)
    .find((candidate) => existsSync(candidate)) || process.execPath
}

function debugBoot(stage, details = {}) {
  if (process.env.ROACHNET_DEBUG_BOOT !== '1') {
    return
  }

  const storageLogsDir = getStorageLogsDir(process.env)
  const launcherDebugLogPath = getLauncherDebugLogPath(process.env)
  mkdirSync(storageLogsDir, { recursive: true })
  appendFileSync(
    launcherDebugLogPath,
    `[${new Date().toISOString()}] ${stage} ${JSON.stringify(details)}\n`,
    'utf8'
  )
}

function getPersistentStorageRoot() {
  return path.join(adminDir, 'storage')
}

function getContainedRuntimeCacheRoot(runtimeEnvValues) {
  const storageRoot = normalizeStorageRoot(runtimeEnvValues?.NOMAD_STORAGE_PATH)
  return path.join(storageRoot, 'state', 'runtime-cache')
}

function normalizeStorageRoot(candidatePath) {
  const fallbackRoot = getPersistentStorageRoot()
  const trimmedPath = candidatePath?.trim()

  if (!trimmedPath) {
    return fallbackRoot
  }

  const resolvedPath = path.resolve(trimmedPath)
  const currentRepoRoot = path.resolve(repoRoot)
  const currentRepoStorageRoot = path.resolve(fallbackRoot)
  const currentRepoAdminRoot = path.resolve(adminDir)

  if (
    resolvedPath === currentRepoStorageRoot ||
    resolvedPath.startsWith(`${currentRepoStorageRoot}${path.sep}`) ||
    resolvedPath.startsWith(`${currentRepoAdminRoot}${path.sep}`) ||
    process.env.ROACHNET_ALLOW_FOREIGN_STORAGE_PATH === '1'
  ) {
    return resolvedPath
  }

  const looksLikeMovedRepoStorageRoot =
    resolvedPath.endsWith(path.join('admin', 'storage')) ||
    resolvedPath.includes(`${path.sep}RoachNet${path.sep}admin${path.sep}storage`)

  if (looksLikeMovedRepoStorageRoot && !resolvedPath.startsWith(`${currentRepoRoot}${path.sep}`)) {
    debugBoot('runtime-env:rewire-storage-root', {
      from: resolvedPath,
      to: currentRepoStorageRoot,
    })
    return currentRepoStorageRoot
  }

  return resolvedPath
}

function getManagedRuntimeStateRoot(envValues) {
  const explicitRoot =
    envValues.ROACHNET_RUNTIME_STATE_ROOT?.trim() ||
    process.env.ROACHNET_RUNTIME_STATE_ROOT?.trim()

  if (explicitRoot) {
    return explicitRoot
  }

  return path.join(normalizeStorageRoot(getRuntimeEnvValues(envValues).NOMAD_STORAGE_PATH), 'state', 'runtime-state')
}

function getManagedComposeInstallKey(envValues) {
  return getManagedRuntimeStateRoot(envValues)
}

function getManagedComposeProjectName(envValues) {
  return getRoachNetComposeProjectName(getManagedComposeInstallKey(envValues))
}

function getManagedRuntimeSecretsPath(envValues) {
  return path.join(getManagedRuntimeStateRoot(envValues), MANAGED_RUNTIME_SECRETS_FILENAME)
}

function getManagedRuntimeSecrets(envValues) {
  const runtimeStateRoot = getManagedRuntimeStateRoot(envValues)
  const secretsPath = getManagedRuntimeSecretsPath(envValues)
  const mysqlStatePath = path.join(runtimeStateRoot, 'mysql')
  const hasExistingManagedDatabase =
    existsSync(mysqlStatePath) && readdirSync(mysqlStatePath).length > 0
  const compatibilityOrigin = hasExistingManagedDatabase ? 'legacy-compatible' : 'generated'
  const fallbackAppKey = envValues.APP_KEY?.trim() || randomSecret(24)
  const fallbackDbPassword =
    envValues.DB_PASSWORD?.trim() ||
    (hasExistingManagedDatabase ? LEGACY_MANAGED_RUNTIME_DB_PASSWORD : randomSecret(16))
  const fallbackDbRootPassword =
    envValues.ROACHNET_DB_ROOT_PASSWORD?.trim() ||
    (hasExistingManagedDatabase ? LEGACY_MANAGED_RUNTIME_DB_ROOT_PASSWORD : randomSecret(16))

  mkdirSync(runtimeStateRoot, { recursive: true })

  if (existsSync(secretsPath)) {
    try {
      const parsed = JSON.parse(readFileSync(secretsPath, 'utf8'))
      const origin = parsed?.origin || compatibilityOrigin
      const normalizedSecrets = {
        origin,
        appKey: envValues.APP_KEY?.trim() || parsed?.appKey || fallbackAppKey,
        dbPassword:
          envValues.DB_PASSWORD?.trim() ||
          (origin === 'generated'
            ? parsed?.dbPassword || fallbackDbPassword
            : fallbackDbPassword),
        dbRootPassword:
          envValues.ROACHNET_DB_ROOT_PASSWORD?.trim() ||
          (origin === 'generated'
            ? parsed?.dbRootPassword || fallbackDbRootPassword
            : fallbackDbRootPassword),
        generatedAt: parsed?.generatedAt || new Date().toISOString(),
      }

      if (JSON.stringify(parsed) !== JSON.stringify(normalizedSecrets)) {
        writeFileSync(secretsPath, `${JSON.stringify(normalizedSecrets, null, 2)}\n`, {
          encoding: 'utf8',
          mode: 0o600,
        })
      }

      return normalizedSecrets
    } catch {
      // Regenerate malformed state below.
    }
  }

  const secrets = {
    origin: compatibilityOrigin,
    appKey: fallbackAppKey,
    dbPassword: fallbackDbPassword,
    dbRootPassword: fallbackDbRootPassword,
    generatedAt: new Date().toISOString(),
  }

  writeFileSync(secretsPath, `${JSON.stringify(secrets, null, 2)}\n`, {
    encoding: 'utf8',
    mode: 0o600,
  })

  return secrets
}

function collectNativeRuntimeArtifacts(rootPath) {
  if (!rootPath || !existsSync(rootPath)) {
    return []
  }

  const artifacts = []
  const pending = [rootPath]

  while (pending.length > 0) {
    const currentPath = pending.pop()
    const entries = readdirSync(currentPath, { withFileTypes: true })

    for (const entry of entries) {
      const nextPath = path.join(currentPath, entry.name)

      if (entry.isDirectory()) {
        pending.push(nextPath)
        continue
      }

      if (!entry.isFile()) {
        continue
      }

      if (entry.name.endsWith('.node') || entry.name.endsWith('.dylib')) {
        artifacts.push(nextPath)
      }
    }
  }

  return artifacts
}

async function stripRuntimeExtendedAttributes(targetPath) {
  if (process.platform !== 'darwin' || !targetPath || !existsSync(targetPath)) {
    return
  }

  for (const attributeName of ['com.apple.quarantine', 'com.apple.provenance']) {
    try {
      await runCommand('/usr/bin/xattr', ['-dr', attributeName, targetPath], {
        cwd: repoRoot,
        env: process.env,
      })
    } catch {
      // Ignore missing xattrs and keep the contained runtime moving.
    }
  }
}

async function ensureRuntimeArtifactsSigned(runtimeDir, fingerprint) {
  if (process.platform !== 'darwin' || !runtimeDir || !existsSync(runtimeDir)) {
    return
  }

  const stampPath = path.join(runtimeDir, BUILD_RUNTIME_CODESIGN_STAMP_FILENAME)
  const expectedStamp = `${BUILD_RUNTIME_CODESIGN_VERSION}:${fingerprint.dependencyHash}`
  const currentStamp = existsSync(stampPath) ? readFileSync(stampPath, 'utf8').trim() : ''

  if (currentStamp === expectedStamp) {
    return
  }

  await stripRuntimeExtendedAttributes(runtimeDir)

  const artifacts = collectNativeRuntimeArtifacts(runtimeDir)
  for (const artifactPath of artifacts) {
    await runCommand('/usr/bin/codesign', ['--force', '--sign', '-', artifactPath], {
      cwd: repoRoot,
      env: process.env,
    })
  }

  await runCommand('/usr/bin/xattr', ['-cr', runtimeDir], {
    cwd: repoRoot,
    env: process.env,
  }).catch(() => {
    // Keep the contained runtime usable even if one artifact rejects a full recursive clear.
  })

  writeFileSync(stampPath, `${expectedStamp}\n`, 'utf8')
}

function resolveComparablePath(targetPath) {
  try {
    return realpathSync(targetPath)
  } catch {
    return path.resolve(targetPath)
  }
}

function matchesBundledDependencyTarget(runtimeNodeModulesPath, bundledRuntimeNodeModulesPath) {
  if (!existsSync(runtimeNodeModulesPath)) {
    return false
  }

  try {
    if (!lstatSync(runtimeNodeModulesPath).isSymbolicLink()) {
      return false
    }
  } catch {
    return false
  }

  return resolveComparablePath(runtimeNodeModulesPath) === resolveComparablePath(bundledRuntimeNodeModulesPath)
}

function pathExistsIncludingBrokenSymlink(targetPath) {
  try {
    lstatSync(targetPath)
    return true
  } catch {
    return false
  }
}

async function refreshBundledRuntimeDependencies(
  runtimeNodeModulesPath,
  bundledRuntimeNodeModulesPath,
  runtimeDependencyStampPath,
  fingerprint
) {
  if (pathExistsIncludingBrokenSymlink(runtimeNodeModulesPath)) {
    rmSync(runtimeNodeModulesPath, { recursive: true, force: true })
  }

  if (process.platform === 'win32') {
    await cp(bundledRuntimeNodeModulesPath, runtimeNodeModulesPath, {
      recursive: true,
      force: true,
      dereference: false,
    })
  } else {
    const runtimeNodeModulesParent = resolveComparablePath(path.dirname(runtimeNodeModulesPath))
    const bundledRuntimeNodeModulesRealPath = resolveComparablePath(bundledRuntimeNodeModulesPath)
    const relativeTarget = path.relative(runtimeNodeModulesParent, bundledRuntimeNodeModulesRealPath)
    symlinkSync(relativeTarget, runtimeNodeModulesPath, 'dir')
  }

  writeFileSync(runtimeDependencyStampPath, `${fingerprint.dependencyHash}\n`, 'utf8')
}

function getRuntimeEnvValues(envValues) {
  const storageRoot = normalizeStorageRoot(
    process.env.NOMAD_STORAGE_PATH?.trim() || envValues.NOMAD_STORAGE_PATH?.trim()
  )
  const manifestsBaseUrl =
    process.env.ROACHNET_MANIFESTS_BASE_URL?.trim() ||
    envValues.ROACHNET_MANIFESTS_BASE_URL?.trim() ||
    'https://roachnet.org/collections'
  const configuredOpenClawWorkspace =
    process.env.OPENCLAW_WORKSPACE_PATH?.trim() || envValues.OPENCLAW_WORKSPACE_PATH?.trim()
  const configuredCompanionEnabled =
    process.env.ROACHNET_COMPANION_ENABLED?.trim() ||
    envValues.ROACHNET_COMPANION_ENABLED?.trim() ||
    ''
  const configuredCompanionHost =
    process.env.ROACHNET_COMPANION_HOST?.trim() ||
    envValues.ROACHNET_COMPANION_HOST?.trim() ||
    DEFAULT_COMPANION_HOST
  const configuredCompanionPort =
    process.env.ROACHNET_COMPANION_PORT?.trim() ||
    envValues.ROACHNET_COMPANION_PORT?.trim() ||
    DEFAULT_COMPANION_PORT
  const configuredCompanionToken =
    process.env.ROACHNET_COMPANION_TOKEN?.trim() ||
    envValues.ROACHNET_COMPANION_TOKEN?.trim() ||
    ''
  const configuredCompanionAdvertisedUrl =
    process.env.ROACHNET_COMPANION_ADVERTISED_URL?.trim() ||
    envValues.ROACHNET_COMPANION_ADVERTISED_URL?.trim() ||
    ''

  return {
    ...envValues,
    NOMAD_STORAGE_PATH: storageRoot,
    ROACHNET_MANIFESTS_BASE_URL: manifestsBaseUrl,
    SQLITE_DB_PATH:
      process.env.SQLITE_DB_PATH?.trim() ||
      envValues.SQLITE_DB_PATH?.trim() ||
      path.join(storageRoot, 'state', 'roachnet.sqlite'),
    ROACHNET_CONTAINERLESS_MODE:
      process.env.ROACHNET_CONTAINERLESS_MODE?.trim() ||
      envValues.ROACHNET_CONTAINERLESS_MODE?.trim() ||
      '',
    ROACHNET_DISABLE_QUEUE:
      process.env.ROACHNET_DISABLE_QUEUE?.trim() ||
      envValues.ROACHNET_DISABLE_QUEUE?.trim() ||
      '',
    ROACHNET_COMPANION_ENABLED: configuredCompanionEnabled,
    ROACHNET_COMPANION_HOST: configuredCompanionHost,
    ROACHNET_COMPANION_PORT: configuredCompanionPort,
    ROACHNET_COMPANION_TOKEN: configuredCompanionToken,
    ROACHNET_COMPANION_ADVERTISED_URL: configuredCompanionAdvertisedUrl,
    OPENCLAW_WORKSPACE_PATH:
      configuredOpenClawWorkspace ? path.resolve(configuredOpenClawWorkspace) : path.join(storageRoot, 'openclaw'),
  }
}

function wantsCompanionRuntime(envValues) {
  const rawMode = envValues.ROACHNET_COMPANION_ENABLED?.trim() || ''
  if (rawMode) {
    return isTruthyFlag(rawMode)
  }

  return Boolean(envValues.ROACHNET_COMPANION_TOKEN?.trim())
}

function getCompanionListenHost(envValues) {
  return envValues.ROACHNET_COMPANION_HOST?.trim() || DEFAULT_COMPANION_HOST
}

function getCompanionPort(envValues) {
  return envValues.ROACHNET_COMPANION_PORT?.trim() || DEFAULT_COMPANION_PORT
}

function getCompanionLocalUrl(envValues) {
  if (!wantsCompanionRuntime(envValues)) {
    return null
  }

  const listenHost = getCompanionListenHost(envValues)
  const localHost =
    listenHost === '0.0.0.0' || listenHost === '::' || listenHost === '[::]'
      ? '127.0.0.1'
      : listenHost

  return `http://${formatUrlHost(localHost)}:${getCompanionPort(envValues)}`
}

function getCompanionAdvertisedUrl(envValues) {
  if (!wantsCompanionRuntime(envValues)) {
    return null
  }

  const explicitAdvertisedUrl = envValues.ROACHNET_COMPANION_ADVERTISED_URL?.trim()
  if (explicitAdvertisedUrl) {
    return explicitAdvertisedUrl
  }

  return getDisplayUrl(getCompanionLocalUrl(envValues), envValues).toString()
}

function readLatestSourceServerUrl(logPath = getServerLogPath(process.env)) {
  if (!existsSync(logPath)) {
    return null
  }

  const lines = readFileSync(logPath, 'utf8').split(/\r?\n/)
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index]
    const bannerMatch = line.match(/Server address:\s+(http:\/\/[^\s]+)/)
    if (bannerMatch?.[1]) {
      return bannerMatch[1]
    }

    const fallbackMatch = line.match(/started HTTP server on ([^\s]+)/)
    if (fallbackMatch?.[1]) {
      return `http://${fallbackMatch[1]}`
    }
  }

  return null
}

function wantsContainerlessRuntime(envValues) {
  const rawMode =
    process.env.ROACHNET_CONTAINERLESS_MODE?.trim() ||
    envValues.ROACHNET_CONTAINERLESS_MODE?.trim() ||
    ''

  return ['1', 'true', 'contained', 'containerless', 'local'].includes(rawMode.toLowerCase())
}

function getBuildRuntimeEnvValues(envValues, options = {}) {
  const runtimeValues = getRuntimeEnvValues(envValues)
  const runtimeSecrets = getManagedRuntimeSecrets(envValues)
  const containerlessMode = options.forceContainerless || wantsContainerlessRuntime(runtimeValues)
  const runtimeHost = runtimeValues.HOST?.trim() || '127.0.0.1'
  const runtimePort = String(runtimeValues.PORT?.trim() || '8080')
  const runtimeUrl = runtimeValues.URL?.trim() || `http://${formatUrlHost(runtimeHost)}:${runtimePort}`

  if (containerlessMode) {
    return {
      ...runtimeValues,
      HOST: runtimeHost,
      PORT: runtimePort,
      URL: runtimeUrl,
      APP_KEY: runtimeSecrets.appKey,
      DB_CONNECTION: 'sqlite',
      SQLITE_DB_PATH: runtimeValues.SQLITE_DB_PATH,
      REDIS_HOST: runtimeValues.REDIS_HOST || '127.0.0.1',
      REDIS_PORT: runtimeValues.REDIS_PORT || BUILD_RUNTIME_REDIS_PORT,
      OLLAMA_BASE_URL: runtimeValues.OLLAMA_BASE_URL || 'http://127.0.0.1:11434',
      OPENCLAW_BASE_URL: runtimeValues.OPENCLAW_BASE_URL || `http://127.0.0.1:${BUILD_RUNTIME_OPENCLAW_PORT}`,
      ROACHNET_DISABLE_QUEUE: '1',
      ROACHNET_DISABLE_TRANSMIT: '1',
      ROACHNET_NATIVE_ONLY: '1',
      ROACHNET_RECONCILE_ON_STARTUP: '0',
    }
  }

  return {
    ...runtimeValues,
    HOST: runtimeHost,
    PORT: runtimePort,
    URL: runtimeUrl,
    APP_KEY: runtimeSecrets.appKey,
    DB_HOST: '127.0.0.1',
    DB_PORT: BUILD_RUNTIME_MYSQL_PORT,
    DB_DATABASE: MANAGED_RUNTIME_DB_DATABASE,
    DB_USER: MANAGED_RUNTIME_DB_USER,
    DB_PASSWORD: runtimeSecrets.dbPassword,
    REDIS_HOST: '127.0.0.1',
    REDIS_PORT: BUILD_RUNTIME_REDIS_PORT,
    QDRANT_URL: `http://127.0.0.1:${BUILD_RUNTIME_QDRANT_PORT}`,
    OLLAMA_BASE_URL: `http://127.0.0.1:${BUILD_RUNTIME_OLLAMA_PORT}`,
    OPENCLAW_BASE_URL: `http://127.0.0.1:${BUILD_RUNTIME_OPENCLAW_PORT}`,
    ROACHNET_DISABLE_TRANSMIT: '1',
    ROACHNET_NATIVE_ONLY: '1',
    ROACHNET_RECONCILE_ON_STARTUP: '0',
  }
}

function getOpenClawRuntimeEnvValues(runtimeEnvValues) {
  const workspacePath =
    runtimeEnvValues.OPENCLAW_WORKSPACE_PATH || path.join(runtimeEnvValues.NOMAD_STORAGE_PATH, 'openclaw')
  const stateDir = path.join(workspacePath, '.openclaw-runtime')
  const configPath = path.join(stateDir, 'openclaw.json')

  return {
    workspacePath,
    stateDir,
    configPath,
    baseUrl:
      runtimeEnvValues.OPENCLAW_BASE_URL?.trim() ||
      `http://127.0.0.1:${BUILD_RUNTIME_OPENCLAW_PORT}`,
  }
}

function ensureOpenClawRuntimeConfig(runtimeEnvValues) {
  const gatewayEnvValues = getOpenClawRuntimeEnvValues(runtimeEnvValues)
  const defaultModel =
    runtimeEnvValues.ROACHNET_ROACHCLAW_DEFAULT_MODEL?.trim() || 'qwen2.5-coder:1.5b'
  const ollamaBaseUrl =
    runtimeEnvValues.OLLAMA_BASE_URL?.trim() || `http://127.0.0.1:${BUILD_RUNTIME_OLLAMA_PORT}`

  mkdirSync(gatewayEnvValues.stateDir, { recursive: true })
  mkdirSync(gatewayEnvValues.workspacePath, { recursive: true })

  let existingConfig = {}
  if (existsSync(gatewayEnvValues.configPath)) {
    try {
      existingConfig = JSON.parse(readFileSync(gatewayEnvValues.configPath, 'utf8'))
    } catch {
      existingConfig = {}
    }
  }

  const existingModels = existingConfig.models ?? {}
  const existingProviders = existingModels.providers ?? {}
  const existingOllama = existingProviders.ollama ?? {}
  const existingAgents = existingConfig.agents ?? {}
  const existingDefaults = existingAgents.defaults ?? {}
  const existingDefaultModel = existingDefaults.model ?? {}
  const existingDefaultModels = existingDefaults.models ?? {}
  const selectedModelId = `ollama/${defaultModel}`

  const nextConfig = {
    ...existingConfig,
    meta: {
      ...(existingConfig.meta ?? {}),
      lastTouchedAt: new Date().toISOString(),
      lastTouchedVersion: existingConfig.meta?.lastTouchedVersion ?? 'roachnet-native',
    },
    models: {
      ...existingModels,
      providers: {
        ...existingProviders,
        ollama: {
          ...existingOllama,
          baseUrl: ollamaBaseUrl,
          apiKey: 'ollama-local',
          api: 'ollama',
          models: Array.isArray(existingOllama.models) ? existingOllama.models : [],
        },
      },
    },
    agents: {
      ...existingAgents,
      defaults: {
        ...existingDefaults,
        workspace: gatewayEnvValues.workspacePath,
        model: {
          ...existingDefaultModel,
          primary: selectedModelId,
        },
        models: {
          ...existingDefaultModels,
          [selectedModelId]: existingDefaultModels[selectedModelId] ?? {},
        },
      },
    },
    commands: {
      ...(existingConfig.commands ?? {}),
      native: 'auto',
      nativeSkills: 'auto',
      restart: true,
      ownerDisplay: 'raw',
    },
    gateway: {
      ...(existingConfig.gateway ?? {}),
      mode: 'local',
    },
  }

  writeFileSync(gatewayEnvValues.configPath, `${JSON.stringify(nextConfig, null, 2)}\n`)
  return gatewayEnvValues
}

function getManagedRuntimeEnvValues(envValues) {
  const runtimeValues = getRuntimeEnvValues(envValues)
  const storageRoot = runtimeValues.NOMAD_STORAGE_PATH
  const runtimeSecrets = getManagedRuntimeSecrets(envValues)

  return {
    ...process.env,
    ...runtimeValues,
    APP_KEY: runtimeSecrets.appKey,
    DB_PASSWORD: runtimeSecrets.dbPassword,
    ROACHNET_DB_ROOT_PASSWORD: runtimeSecrets.dbRootPassword,
    ROACHNET_REPO_ROOT: repoRoot,
    ROACHNET_HOST_STORAGE_PATH: storageRoot,
    ROACHNET_RUNTIME_STATE_ROOT: getManagedRuntimeStateRoot(envValues),
  }
}

function escapeSqlString(value) {
  return String(value).replace(/'/g, "''")
}

async function repairManagedRuntimeDatabaseUser(envValues) {
  const managedEnv = getManagedRuntimeEnvValues(envValues)
  const sql = [
    `CREATE DATABASE IF NOT EXISTS \`${MANAGED_RUNTIME_DB_DATABASE}\`;`,
    `CREATE USER IF NOT EXISTS '${MANAGED_RUNTIME_DB_USER}'@'%' IDENTIFIED BY '${escapeSqlString(managedEnv.DB_PASSWORD)}';`,
    `ALTER USER '${MANAGED_RUNTIME_DB_USER}'@'%' IDENTIFIED BY '${escapeSqlString(managedEnv.DB_PASSWORD)}';`,
    `GRANT ALL PRIVILEGES ON \`${MANAGED_RUNTIME_DB_DATABASE}\`.* TO '${MANAGED_RUNTIME_DB_USER}'@'%';`,
    'FLUSH PRIVILEGES;',
  ].join(' ')

  await runCommand(
    'docker',
    [
      'compose',
      '-p',
      getRoachNetComposeProjectName(getManagedComposeInstallKey(managedEnv)),
      '-f',
      managementComposePath,
      'exec',
      '-T',
      'mysql',
      'mysql',
      '-uroot',
      `-p${managedEnv.ROACHNET_DB_ROOT_PASSWORD}`,
      '-e',
      sql,
    ],
    {
      cwd: repoRoot,
      env: managedEnv,
    }
  )
}

function getSourceRuntimeTarget() {
  return {
    cwd: adminDir,
    entrypoint: path.join(adminDir, 'bin', 'server.ts'),
    kind: 'source',
  }
}

function canRunSourceRuntime(target = getSourceRuntimeTarget()) {
  if (!existsSync(target.entrypoint)) {
    return false
  }

  if (path.extname(target.entrypoint) !== '.ts') {
    return true
  }

  return existsSync(path.join(target.cwd, 'node_modules', 'ts-node-maintained'))
}

function getServerRuntimeTarget() {
  if (process.env.ROACHNET_USE_SOURCE === '1') {
    return getSourceRuntimeTarget()
  }

  if (existsSync(buildEntrypointPath)) {
    return {
      cwd: buildDir,
      entrypoint: 'bin/server.js',
      kind: 'build',
    }
  }

  if (existsSync(managementComposePath)) {
    return {
      cwd: repoRoot,
      entrypoint: managementComposePath,
      kind: 'docker',
    }
  }

  return getSourceRuntimeTarget()
}

function openBrowser(url) {
  if (process.env.ROACHNET_NO_BROWSER === '1') {
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

function writeServerInfo(info) {
  const outputPath = process.env.ROACHNET_SERVER_INFO_FILE
  if (!outputPath) {
    return
  }

  mkdirSync(path.dirname(outputPath), { recursive: true })
  writeFileSync(outputPath, JSON.stringify(info, null, 2) + '\n', 'utf8')
}

function writeRuntimeProcessInfo(info, envValues = process.env) {
  const storageLogsDir = getStorageLogsDir(envValues)
  const runtimeProcessInfoPath = getRuntimeProcessInfoPath(envValues)
  mkdirSync(storageLogsDir, { recursive: true })
  writeFileSync(runtimeProcessInfoPath, JSON.stringify(info, null, 2) + '\n', 'utf8')
}

function readRuntimeProcessInfo(envValues = process.env) {
  const runtimeProcessInfoPath = getRuntimeProcessInfoPath(envValues)
  if (!existsSync(runtimeProcessInfoPath)) {
    return null
  }

  try {
    return JSON.parse(readFileSync(runtimeProcessInfoPath, 'utf8'))
  } catch {
    return null
  }
}

function clearRuntimeProcessInfo(envValues = process.env) {
  const runtimeProcessInfoPath = getRuntimeProcessInfoPath(envValues)
  rmSync(runtimeProcessInfoPath, { force: true })
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function isPidRunning(pid) {
  if (!pid || Number.isNaN(Number(pid))) {
    return false
  }

  try {
    process.kill(Number(pid), 0)
    return true
  } catch {
    return false
  }
}

async function listManagedRuntimeProcesses() {
  const escapedRepoRoot = repoRoot.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const escapedBuildDir = buildDir.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const patterns = [
    /roachnet-runtime-cache\/.+\/bin\/(?:server|worker)\.js/,
    new RegExp(`${escapedBuildDir}/bin/(?:server|worker)\\.js`),
    new RegExp(`${escapedRepoRoot}/admin/ace\\.js\\s+(?:serve|queue:listen)`),
    new RegExp(`${escapedRepoRoot}/admin/bin/(?:server|worker)\\.ts`),
    new RegExp(`${escapedRepoRoot}/scripts/roachnet-companion-server\\.mjs`),
  ]

  let output = ''
  try {
    const result = await runCommand('ps', ['axww', '-o', 'pid=,command='], {
      cwd: repoRoot,
      env: process.env,
    })
    output = result.stdout
  } catch {
    return []
  }

  return output
    .split(/\r?\n/)
    .map((line) => line.match(/^\s*(\d+)\s+(.*)$/))
    .filter(Boolean)
    .map((match) => ({
      pid: Number(match[1]),
      command: match[2],
    }))
    .filter(({ pid, command }) => {
      if (!pid || pid === process.pid) {
        return false
      }

      return patterns.some((pattern) => pattern.test(command))
    })
}

function terminateManagedPid(pid, signal) {
  if (!pid) {
    return
  }

  try {
    if (process.platform !== 'win32') {
      process.kill(-pid, signal)
      return
    }
  } catch {
    // Fall back to the direct pid below.
  }

  try {
    process.kill(pid, signal)
  } catch {
    // The process may already be gone.
  }
}

async function listActiveManagedComposeProjects() {
  let output = ''
  try {
    const result = await runCommand(
      'docker',
      [
        'ps',
        '--filter',
        'label=com.docker.compose.project',
        '--format',
        '{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.config_files"}}',
      ],
      {
        cwd: repoRoot,
        env: process.env,
      }
    )
    output = result.stdout
  } catch {
    return []
  }

  const discoveredProjects = new Set()

  for (const rawLine of output.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (!line) {
      continue
    }

    const [projectName = '', serviceName = '', configFiles = ''] = line.split('\t')
    if (!projectName.startsWith('roachnet-')) {
      continue
    }

    if (!MANAGED_COMPOSE_SERVICE_NAMES.has(serviceName)) {
      continue
    }

    if (!configFiles.includes('roachnet-management.compose.yml')) {
      continue
    }

    discoveredProjects.add(projectName)
  }

  return [...discoveredProjects]
}

async function stopManagedComposeProjects(projectNames, envValues) {
  if (!existsSync(managementComposePath)) {
    return
  }

  const managedEnv = getManagedRuntimeEnvValues(envValues)
  const uniqueProjectNames = [...new Set(projectNames.filter(Boolean).map((projectName) => projectName.trim()))]

  for (const projectName of uniqueProjectNames) {
    try {
      await composeDownRoachNetServices({
        composeFiles: [managementComposePath],
        cwd: repoRoot,
        installPath: getManagedComposeInstallKey(envValues),
        projectName,
        runProcess: runCommand,
        env: managedEnv,
      })
    } catch {
      // Containers may already be down or belong to an older bundle path.
    }
  }
}

async function stopCompetingManagedComposeProjects(envValues) {
  const currentProjectName = getManagedComposeProjectName(envValues)
  const competingProjectNames = (await listActiveManagedComposeProjects()).filter(
    (projectName) => projectName !== currentProjectName
  )

  if (!competingProjectNames.length) {
    return
  }

  debugBoot('managed-support:stop-competing-projects', {
    currentProjectName,
    competingProjectNames,
  })

  await stopManagedComposeProjects(competingProjectNames, envValues)
}

async function listListeningPids(port) {
  try {
    const result = await runCommand('lsof', ['-tiTCP:' + String(port), '-sTCP:LISTEN'], {
      cwd: repoRoot,
      env: process.env,
    })

    return result.stdout
      .split(/\r?\n/)
      .map((line) => Number(line.trim()))
      .filter((pid) => Number.isInteger(pid) && pid > 0)
  } catch {
    return []
  }
}

async function getParentPid(pid) {
  try {
    const result = await runCommand('ps', ['-o', 'ppid=', '-p', String(pid)], {
      cwd: repoRoot,
      env: process.env,
    })
    const parentPid = Number(result.stdout.trim())
    return Number.isInteger(parentPid) && parentPid > 1 ? parentPid : null
  } catch {
    return null
  }
}

async function terminateManagedPortListeners(ports = MANAGED_PORT_FALLBACKS) {
  const uniquePids = new Set()

  for (const port of ports) {
    const listeningPids = await listListeningPids(port)
    for (const pid of listeningPids) {
      uniquePids.add(pid)

      if (String(port) === BUILD_RUNTIME_OPENCLAW_PORT) {
        const parentPid = await getParentPid(pid)
        if (parentPid) {
          uniquePids.add(parentPid)
        }
      }
    }
  }

  if (!uniquePids.size) {
    return
  }

  for (const pid of uniquePids) {
    terminateManagedPid(pid, 'SIGTERM')
  }

  await delay(500)

  for (const pid of uniquePids) {
    if (isPidRunning(pid)) {
      terminateManagedPid(pid, 'SIGKILL')
    }
  }
}

async function terminateManagedRuntimeProcesses(extraPids = []) {
  const discoveredProcesses = await listManagedRuntimeProcesses()
  const allPids = [
    ...extraPids,
    ...discoveredProcesses.map((processInfo) => processInfo.pid),
  ]
  const uniquePids = [...new Set(allPids.filter(Boolean).map((pid) => Number(pid)))]

  for (const pid of uniquePids) {
    terminateManagedPid(pid, 'SIGTERM')
  }

  if (!uniquePids.length) {
    return
  }

  await delay(500)

  for (const pid of uniquePids) {
    if (isPidRunning(pid)) {
      terminateManagedPid(pid, 'SIGKILL')
    }
  }
}

async function runCommand(binary, args, options) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      ...options,
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    let stdout = ''
    let stderr = ''

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString()
    })

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString()
    })

    child.on('error', reject)
    child.on('close', (code) => {
      if (code === 0) {
        resolve({ stdout, stderr })
        return
      }

      reject(
        new Error(
          `${binary} ${args.join(' ')} exited with code ${code}\n${stderr.trim() || stdout.trim()}`
        )
      )
    })
  })
}

async function commandPath(command) {
  const localCandidate = getLocalToolBinaryPath(command.replace(/\.cmd$/i, ''))
  if (existsSync(localCandidate)) {
    return localCandidate
  }

  try {
    const binary = process.platform === 'win32' ? 'where' : 'which'
    const result = await runCommand(binary, [command], {
      cwd: repoRoot,
      env: process.env,
    })
    return result.stdout.split(/\r?\n/).find(Boolean)?.trim() || null
  } catch {
    return null
  }
}

async function commandResponds(command, args = ['--version']) {
  try {
    await runCommand(command, args, {
      cwd: repoRoot,
      env: process.env,
    })
    return true
  } catch {
    return false
  }
}

async function ensureManagedSupportServices(envValues, timeoutMs) {
  if (!existsSync(managementComposePath)) {
    return
  }

  debugBoot('managed-support:start', {
    composePath: managementComposePath,
    runtimeStateRoot: getManagedRuntimeStateRoot(envValues),
  })

  await startRoachNetContainerRuntime({
    commandExists: commandResponds,
    detectRuntime: () =>
      detectRoachNetContainerRuntime({
        commandPath,
        commandExists: commandResponds,
        runProcess: runCommand,
      }),
    runProcess: runCommand,
    runShell(command, options = {}) {
      return runCommand(command, [], {
        ...options,
        shell: true,
      })
    },
    env: process.env,
  })

  await stopCompetingManagedComposeProjects(envValues)

  await composeUpRoachNetServices({
    composeFiles: [managementComposePath],
    cwd: repoRoot,
    installPath: getManagedComposeInstallKey(envValues),
    runProcess: runCommand,
    env: getManagedRuntimeEnvValues(envValues),
    waitTimeoutMs: timeoutMs,
    services: ['mysql', 'redis'],
  })

  try {
    await composeUpRoachNetServices({
      composeFiles: [managementComposePath],
      cwd: repoRoot,
      installPath: getManagedComposeInstallKey(envValues),
      runProcess: runCommand,
      env: getManagedRuntimeEnvValues(envValues),
      services: ['qdrant', 'ollama'],
      wait: false,
    })
  } catch (error) {
    console.warn(
      'Contained qdrant/ollama did not fully start during the non-blocking boot phase. ' +
        `RoachNet will continue booting and retry those lanes later. ${error.message}`
    )
  }

  debugBoot('managed-support:ready', {
    runtimeStateRoot: getManagedRuntimeStateRoot(envValues),
    ollamaReady: null,
  })

  const ollamaHealthUrl = `http://127.0.0.1:${BUILD_RUNTIME_OLLAMA_PORT}/api/version`
  void waitForHttpEndpoint(ollamaHealthUrl, Math.min(timeoutMs, 120_000)).then((ollamaReady) => {
    debugBoot('managed-support:ollama-ready', {
      runtimeStateRoot: getManagedRuntimeStateRoot(envValues),
      ollamaReady,
    })

    if (!ollamaReady) {
      console.warn(
        `Contained Ollama did not answer on :${BUILD_RUNTIME_OLLAMA_PORT} before the support timeout. ` +
          'RoachNet will continue booting, but local chat may remain unavailable until Ollama finishes warming up.'
      )
    }
  })
}

async function stopManagedRuntime(envValues) {
  const runtimeEnvValues = getRuntimeEnvValues(envValues)
  const trackedInfo = readRuntimeProcessInfo(runtimeEnvValues)
  await terminateManagedRuntimeProcesses([
    trackedInfo?.serverPid,
    trackedInfo?.workerPid,
    trackedInfo?.ollamaPid,
    trackedInfo?.openclawPid,
    trackedInfo?.companionPid,
  ])

  if (!existsSync(managementComposePath)) {
    await terminateManagedPortListeners()
    clearRuntimeProcessInfo(runtimeEnvValues)
    return
  }

  const activeProjectNames = await listActiveManagedComposeProjects()
  await stopManagedComposeProjects(
    [getManagedComposeProjectName(envValues), ...activeProjectNames],
    envValues
  )

  await terminateManagedPortListeners()

  clearRuntimeProcessInfo(runtimeEnvValues)
}

function getBuildRuntimeFingerprint() {
  if (!existsSync(buildEntrypointPath) || !existsSync(buildPackageLockPath) || !existsSync(buildPackageJsonPath)) {
    return null
  }

  const buildLockfile = readFileSync(buildPackageLockPath, 'utf8')

  if (existsSync(buildStampPath)) {
    try {
      const buildStamp = JSON.parse(readFileSync(buildStampPath, 'utf8'))
      const stampSignature = hashString(JSON.stringify({
        dependencyHash: buildStamp.dependencyHash,
        serverEntrypointHash: buildStamp.serverEntrypointHash,
        workerEntrypointHash: buildStamp.workerEntrypointHash,
        packageJsonHash: buildStamp.packageJsonHash,
        assetManifestHash: buildStamp.assetManifestHash,
        treeHash: buildStamp.treeHash,
      }))

      return {
        dependencyHash: buildStamp.dependencyHash || hashString(buildLockfile),
        signature: stampSignature,
      }
    } catch {
      // Fall back to hashing the compiled tree when the build stamp is missing or malformed.
    }
  }

  const parts = [
    buildLockfile,
    readFileSync(buildPackageJsonPath, 'utf8'),
    readFileSync(buildEntrypointPath, 'utf8'),
    ...collectBuildSignatureParts(buildDir),
  ]

  if (existsSync(buildAssetManifestPath)) {
    parts.push(`public/assets/.vite/manifest.json\n${readFileSync(buildAssetManifestPath, 'utf8')}`)
  }

  return {
    dependencyHash: hashString(buildLockfile),
    signature: hashString(parts.join('\n---\n')),
  }
}

async function prepareBuildRuntimeTarget(envValues, options = {}) {
  const runtimeEnvValues = getBuildRuntimeEnvValues(envValues, options)
  const fingerprint = getBuildRuntimeFingerprint()

  if (!fingerprint) {
    debugBoot('build-runtime:fingerprint-missing')
    return null
  }

  debugBoot('build-runtime:fingerprint-ready', {
    dependencyHash: fingerprint.dependencyHash,
    signature: fingerprint.signature,
  })

  const runtimeCacheRoot = getContainedRuntimeCacheRoot(runtimeEnvValues)
  const runtimeDir = path.join(runtimeCacheRoot, fingerprint.signature.slice(0, 16))
  const runtimeMetadataPath = path.join(runtimeDir, BUILD_RUNTIME_METADATA_FILENAME)
  const runtimeNodeModulesPath = path.join(runtimeDir, 'node_modules')
  const runtimeDependencyStampPath = path.join(runtimeDir, BUILD_RUNTIME_DEPENDENCY_STAMP_FILENAME)
  const bundledRuntimeNodeModulesPath = path.join(buildDir, 'node_modules')
  const existingSignature = existsSync(runtimeMetadataPath)
    ? JSON.parse(readFileSync(runtimeMetadataPath, 'utf8')).signature
    : null
  const hasStagedEntrypoint = existsSync(path.join(runtimeDir, 'bin', 'server.js'))
  const hasStagedDependencies = existsSync(path.join(runtimeNodeModulesPath, '@adonisjs', 'core'))

  mkdirSync(runtimeCacheRoot, { recursive: true })

  if (
    !hasStagedEntrypoint ||
    existingSignature !== fingerprint.signature
  ) {
    debugBoot('build-runtime:stage-start', {
      runtimeDir,
      hasStagedEntrypoint,
      existingSignature,
      expectedSignature: fingerprint.signature,
    })
    console.log('Staging the compiled RoachNet runtime outside the workspace...')
    rmSync(runtimeDir, { recursive: true, force: true })

    await cp(buildDir, runtimeDir, {
      recursive: true,
      force: true,
      dereference: false,
      filter(sourcePath) {
        const relativePath = path.relative(buildDir, sourcePath)
        if (!relativePath || relativePath === '.') {
          return true
        }

        return relativePath !== 'node_modules' && !relativePath.startsWith(`node_modules${path.sep}`)
      },
    })

    writeFileSync(
      runtimeMetadataPath,
      JSON.stringify({ signature: fingerprint.signature }, null, 2) + '\n',
      'utf8'
    )

    debugBoot('build-runtime:stage-ready', {
      runtimeDir,
    })
  }

  writeFileSync(
    path.join(runtimeDir, '.env'),
    serializeEnvFile({
      ...runtimeEnvValues,
      NODE_ENV: 'production',
    }),
    'utf8'
  )

  const bundledHasCoreDependency = existsSync(path.join(bundledRuntimeNodeModulesPath, '@adonisjs', 'core'))
  let installedHash = existsSync(runtimeDependencyStampPath)
    ? readFileSync(runtimeDependencyStampPath, 'utf8').trim()
    : ''
  let hasCoreDependency = existsSync(path.join(runtimeNodeModulesPath, '@adonisjs', 'core'))

  if (
    bundledHasCoreDependency &&
    (
      !hasCoreDependency ||
      installedHash !== fingerprint.dependencyHash ||
      (process.platform !== 'win32' &&
        existsSync(runtimeNodeModulesPath) &&
        !matchesBundledDependencyTarget(runtimeNodeModulesPath, bundledRuntimeNodeModulesPath))
    )
  ) {
    debugBoot('build-runtime:seed-bundled-deps-start', {
      runtimeDir,
      bundledRuntimeNodeModulesPath,
      mode: process.platform === 'win32' ? 'copy' : 'symlink',
    })
    console.log('Seeding the compiled RoachNet runtime from bundled production dependencies...')
    await refreshBundledRuntimeDependencies(
      runtimeNodeModulesPath,
      bundledRuntimeNodeModulesPath,
      runtimeDependencyStampPath,
      fingerprint
    )
    debugBoot('build-runtime:seed-bundled-deps-ready', {
      runtimeDir,
      mode: process.platform === 'win32' ? 'copy' : 'symlink',
    })
    installedHash = existsSync(runtimeDependencyStampPath)
      ? readFileSync(runtimeDependencyStampPath, 'utf8').trim()
      : ''
    hasCoreDependency = existsSync(path.join(runtimeNodeModulesPath, '@adonisjs', 'core'))
  }

  if (!hasCoreDependency || installedHash !== fingerprint.dependencyHash) {
    debugBoot('build-runtime:install-deps-start', {
      runtimeDir,
      hasCoreDependency,
      installedHash,
      expectedDependencyHash: fingerprint.dependencyHash,
    })
    console.log('Installing production dependencies for the compiled RoachNet runtime...')

    await runCommand(getPreferredNpmBinary(), ['ci', '--omit=dev'], {
      cwd: runtimeDir,
      env: {
        ...process.env,
        ...runtimeEnvValues,
        NODE_ENV: 'production',
        PATH: [
          getLocalBinRoot(),
          path.dirname(getPreferredNodeBinary()),
          process.env.PATH || '',
        ]
          .filter(Boolean)
          .join(path.delimiter),
      },
    })

    writeFileSync(runtimeDependencyStampPath, `${fingerprint.dependencyHash}\n`, 'utf8')
    debugBoot('build-runtime:install-deps-ready', {
      runtimeDir,
    })
  }

  await ensureRuntimeArtifactsSigned(runtimeDir, fingerprint)

  debugBoot('build-runtime:target-ready', {
    runtimeDir,
  })

  return {
    cwd: adminDir,
    entrypoint: path.join(runtimeDir, 'bin', 'server.js'),
    kind: 'build',
  }
}

async function ensureBuildRuntimeDatabaseReady(runtimeRoot, runtimeEnvValues) {
  const consoleEntrypoint = path.join(runtimeRoot, 'bin', 'console.js')

  if (!existsSync(consoleEntrypoint)) {
    debugBoot('build-runtime:db-bootstrap:console-missing', {
      runtimeRoot,
    })
    return
  }

  const preparationFingerprint = createDatabasePreparationFingerprint(runtimeEnvValues)
  const existingPreparationStamp = readPreparedDatabaseStamp(runtimeEnvValues)

  if (existingPreparationStamp?.fingerprint === preparationFingerprint) {
    debugBoot('build-runtime:db-bootstrap:skip', {
      runtimeRoot,
      preparationFingerprint,
    })
    return
  }

  if (runtimeEnvValues.DB_CONNECTION === 'sqlite' && runtimeEnvValues.SQLITE_DB_PATH) {
    mkdirSync(path.dirname(runtimeEnvValues.SQLITE_DB_PATH), { recursive: true })
  }

  const consoleEnv = {
    ...process.env,
    ...runtimeEnvValues,
    NODE_ENV: 'production',
    ROACHNET_DISABLE_TRANSMIT: '1',
    PATH: [
      getLocalBinRoot(),
      path.dirname(getPreferredNodeBinary()),
      process.env.PATH || '',
    ]
      .filter(Boolean)
      .join(path.delimiter),
  }
  const nodeBinary = getPreferredNodeBinary()

  debugBoot('build-runtime:db-bootstrap:start', {
    runtimeRoot,
    preparationFingerprint,
  })
  console.log('Preparing the compiled RoachNet database...')

  try {
    await runCommand(nodeBinary, [consoleEntrypoint, 'migration:run', '--force'], {
      cwd: runtimeRoot,
      env: consoleEnv,
    })
  } catch (error) {
    const normalizedMessage = String(error?.message || '')
      .replace(/\s+/g, ' ')
      .toLowerCase()

    if (!normalizedMessage.includes('access denied')) {
      throw error
    }

    console.warn('Managed MySQL credentials drifted. Repairing the contained database user and retrying...')
    debugBoot('build-runtime:db-bootstrap:repair-user', {
      runtimeRoot,
    })
    await repairManagedRuntimeDatabaseUser(runtimeEnvValues)

    await runCommand(nodeBinary, [consoleEntrypoint, 'migration:run', '--force'], {
      cwd: runtimeRoot,
      env: consoleEnv,
    })
  }

  await runCommand(nodeBinary, [consoleEntrypoint, 'db:seed'], {
    cwd: runtimeRoot,
    env: consoleEnv,
  })

  writePreparedDatabaseStamp(runtimeEnvValues, preparationFingerprint)
  debugBoot('build-runtime:db-bootstrap:ready', {
    runtimeRoot,
    preparationFingerprint,
  })
}

function createDatabasePreparationFingerprint(runtimeEnvValues) {
  const runtimeFingerprint = getBuildRuntimeFingerprint()
  return JSON.stringify({
    runtimeSignature: runtimeFingerprint?.signature ?? 'unknown',
    dbConnection: runtimeEnvValues.DB_CONNECTION ?? null,
    dbHost: runtimeEnvValues.DB_HOST ?? null,
    dbPort: runtimeEnvValues.DB_PORT ?? null,
    dbDatabase: runtimeEnvValues.DB_DATABASE ?? null,
    sqlitePath: runtimeEnvValues.SQLITE_DB_PATH ?? null,
  })
}

function getPreparedDatabaseStampPath(runtimeEnvValues) {
  return path.join(getManagedRuntimeStateRoot(runtimeEnvValues), '.roachnet-db-prepared.json')
}

function readPreparedDatabaseStamp(runtimeEnvValues) {
  const stampPath = getPreparedDatabaseStampPath(runtimeEnvValues)
  if (!existsSync(stampPath)) {
    return null
  }

  try {
    return JSON.parse(readFileSync(stampPath, 'utf8'))
  } catch {
    return null
  }
}

function writePreparedDatabaseStamp(runtimeEnvValues, fingerprint) {
  const stampPath = getPreparedDatabaseStampPath(runtimeEnvValues)
  mkdirSync(path.dirname(stampPath), { recursive: true })
  writeFileSync(
    stampPath,
    JSON.stringify(
      {
        fingerprint,
        preparedAt: new Date().toISOString(),
      },
      null,
      2
    ) + '\n',
    'utf8'
  )
}

function terminateDetachedChild(child) {
  if (!child?.pid) {
    return
  }

  try {
    if (process.platform === 'win32') {
      process.kill(child.pid, 'SIGTERM')
    } else {
      process.kill(-child.pid, 'SIGTERM')
    }
  } catch {
    // The process may have already exited.
  }
}

function recordDetachedRuntimeChildren({
  target,
  serverHandle,
  workerHandle,
  ollamaHandle,
  openclawHandle,
  companionHandle,
  companionUrl = null,
  companionAdvertisedUrl = null,
}) {
  writeRuntimeProcessInfo({
    targetKind: target.kind,
    targetEntrypoint: target.entrypoint,
    serverPid: serverHandle.child?.pid ?? null,
    workerPid: workerHandle?.child?.pid ?? null,
    ollamaPid: ollamaHandle?.child?.pid ?? null,
    openclawPid: openclawHandle?.child?.pid ?? null,
    companionPid: companionHandle?.child?.pid ?? null,
    companionUrl,
    companionAdvertisedUrl,
    writtenAt: new Date().toISOString(),
  })
}

function spawnDetachedProcess({
  binary,
  args = [],
  cwd,
  env,
  logFd,
}) {
  const child = spawn(
    binary,
    args,
    {
      cwd,
      detached: true,
      env,
      stdio: ['ignore', logFd, logFd],
    }
  )

  let exited = false
  child.on('exit', () => {
    exited = true
  })
  child.unref()

  return {
    child,
    hasExited() {
      return exited
    },
  }
}

function spawnDetachedNodeProcess({
  nodeBinary,
  runtimeKind,
  entrypoint,
  args = [],
  cwd,
  env,
  logFd,
}) {
  const shouldUseTypeScriptLoader = runtimeKind === 'source' && path.extname(entrypoint) === '.ts'

  return spawnDetachedProcess({
    binary: nodeBinary,
    args: shouldUseTypeScriptLoader
      ? [
          '--import=ts-node-maintained/register/esm',
          '--enable-source-maps',
          '--disable-warning=ExperimentalWarning',
          entrypoint,
          ...args,
        ]
      : [entrypoint, ...args],
    cwd,
    env,
    logFd,
  })
}

async function maybeSpawnOpenClawGateway({ runtimeEnvValues, logFd }) {
  const openclawBinary = await commandPath('openclaw')
  const gatewayEnvValues = ensureOpenClawRuntimeConfig(runtimeEnvValues)
  const gatewayUrl = new URL(gatewayEnvValues.baseUrl)
  const port = gatewayUrl.port || BUILD_RUNTIME_OPENCLAW_PORT

  mkdirSync(gatewayEnvValues.stateDir, { recursive: true })
  mkdirSync(gatewayEnvValues.workspacePath, { recursive: true })

  const childEnv = {
    ...process.env,
    ...runtimeEnvValues,
    OPENCLAW_STATE_DIR: gatewayEnvValues.stateDir,
    OPENCLAW_CONFIG_PATH: gatewayEnvValues.configPath,
    OPENCLAW_WORKSPACE_PATH: gatewayEnvValues.workspacePath,
  }

  if (openclawBinary) {
    return spawnDetachedProcess({
      binary: openclawBinary,
      args: [
        'gateway',
        'run',
        '--allow-unconfigured',
        '--auth',
        'none',
        '--bind',
        'loopback',
        '--port',
        port,
      ],
      cwd: repoRoot,
      env: childEnv,
      logFd,
    })
  }

  return null
}

async function maybeSpawnCompanionServer({
  nodeBinary,
  runtimeEnvValues,
  targetUrl,
  logFd,
}) {
  if (!wantsCompanionRuntime(runtimeEnvValues)) {
    return {
      handle: null,
      localUrl: null,
      advertisedUrl: null,
    }
  }

  const companionEntrypoint = path.join(repoRoot, 'scripts', 'roachnet-companion-server.mjs')
  if (!existsSync(companionEntrypoint)) {
    console.warn('RoachNet companion server entrypoint is missing. Skipping companion boot.')
    return {
      handle: null,
      localUrl: null,
      advertisedUrl: null,
    }
  }

  const token = runtimeEnvValues.ROACHNET_COMPANION_TOKEN?.trim()
  if (!token) {
    console.warn('RoachNet companion mode was requested without a companion token. Skipping companion boot.')
    return {
      handle: null,
      localUrl: null,
      advertisedUrl: null,
    }
  }

  const localUrl = getCompanionLocalUrl(runtimeEnvValues)
  const advertisedUrl = getCompanionAdvertisedUrl(runtimeEnvValues)
  const targetOrigin = new URL('/', targetUrl).toString()
  const companionEnv = {
    ...process.env,
    ...runtimeEnvValues,
    ROACHNET_COMPANION_ENABLED: '1',
    ROACHNET_COMPANION_HOST: getCompanionListenHost(runtimeEnvValues),
    ROACHNET_COMPANION_PORT: getCompanionPort(runtimeEnvValues),
    ROACHNET_COMPANION_TOKEN: token,
    ROACHNET_COMPANION_ADVERTISED_URL: advertisedUrl || '',
    ROACHNET_COMPANION_TARGET_URL: targetOrigin,
  }

  debugBoot('launch-server:spawn-companion', {
    companionEntrypoint,
    localUrl,
    advertisedUrl,
    targetOrigin,
  })

  const handle = spawnDetachedNodeProcess({
    nodeBinary,
    runtimeKind: 'build',
    entrypoint: companionEntrypoint,
    cwd: repoRoot,
    env: companionEnv,
    logFd,
  })

  if (localUrl) {
    const ready = await waitForHttpEndpoint(
      new URL('/health', localUrl).toString(),
      15_000
    )

    if (!ready) {
      console.warn(`RoachNet companion did not answer on ${localUrl} before the local timeout.`)
    }
  }

  return {
    handle,
    localUrl,
    advertisedUrl,
  }
}

function resolveCompanionTargetUrl({ resolvedTarget, healthyUrl }) {
  if (resolvedTarget.kind !== 'source') {
    return healthyUrl
  }

  return readLatestSourceServerUrl() || healthyUrl
}

async function maybeSpawnContainedOllama({ runtimeEnvValues, logFd }) {
  const baseUrl = runtimeEnvValues.OLLAMA_BASE_URL?.trim()
  if (!baseUrl) {
    return null
  }

  const ollamaBinary = await commandPath('ollama')
  if (!ollamaBinary) {
    return null
  }

  const parsedBaseUrl = new URL(baseUrl)
  const host = parsedBaseUrl.hostname || '127.0.0.1'
  const port = parsedBaseUrl.port || '11434'
  const storageRoot = normalizeStorageRoot(runtimeEnvValues.NOMAD_STORAGE_PATH)
  const modelsPath =
    runtimeEnvValues.OLLAMA_MODELS?.trim() ||
    path.join(storageRoot || getPersistentStorageRoot(), 'ollama')
  const ollamaHomeRoot = path.join(storageRoot || getPersistentStorageRoot(), 'state', 'ollama-home')
  const dotOllamaPath = path.join(ollamaHomeRoot, '.ollama')
  const registryPrivateKeyPath = path.join(dotOllamaPath, 'id_ed25519')
  const registryPublicKeyPath = `${registryPrivateKeyPath}.pub`

  mkdirSync(modelsPath, { recursive: true })
  mkdirSync(ollamaHomeRoot, { recursive: true })

  if (existsSync(dotOllamaPath)) {
    const dotOllamaStats = lstatSync(dotOllamaPath)
    if (!dotOllamaStats.isDirectory() || dotOllamaStats.isSymbolicLink()) {
      rmSync(dotOllamaPath, { recursive: true, force: true })
    }
  }

  mkdirSync(dotOllamaPath, { recursive: true })

  if (!existsSync(registryPrivateKeyPath) || !existsSync(registryPublicKeyPath)) {
    await runCommand(
      'ssh-keygen',
      ['-q', '-t', 'ed25519', '-N', '', '-f', registryPrivateKeyPath],
      {
        env: {
          ...process.env,
          HOME: ollamaHomeRoot,
        },
        timeoutMs: 20_000,
      }
    )
  }

  if (await waitForHttpEndpoint(new URL('/api/version', parsedBaseUrl).toString(), 1_000)) {
    return null
  }

  return spawnDetachedProcess({
    binary: ollamaBinary,
    args: ['serve'],
    cwd: repoRoot,
    env: {
      ...process.env,
      ...runtimeEnvValues,
      HOME: ollamaHomeRoot,
      OLLAMA_HOST: `${host}:${port}`,
      OLLAMA_HOME: dotOllamaPath,
      OLLAMA_MODELS: modelsPath,
    },
    logFd,
  })
}

async function launchServer(target, envValues, healthUrls, timeoutMs, serverLogFd) {
  debugBoot('launch-server:start', {
    targetKind: target.kind,
    targetEntrypoint: target.entrypoint,
  })

  if (target.kind === 'docker') {
    await startRoachNetContainerRuntime({
      commandExists: commandResponds,
      detectRuntime: () =>
        detectRoachNetContainerRuntime({
          commandPath,
          commandExists: commandResponds,
          runProcess: runCommand,
        }),
      runProcess: runCommand,
      runShell(command, options = {}) {
        return runCommand(command, [], {
          ...options,
          shell: true,
        })
      },
      env: process.env,
    })

    await composeUpRoachNetServices({
      composeFiles: [target.entrypoint],
      cwd: target.cwd,
      installPath: getManagedComposeInstallKey(envValues),
      runProcess: runCommand,
      env: process.env,
      waitTimeoutMs: timeoutMs,
      services: ['admin'],
    })

    const healthyUrl = await waitForHealth(healthUrls, timeoutMs)

    return {
      child: null,
      childExited: false,
      healthyUrl,
      target,
    }
  }

  const nodeBinary = getPreferredNodeBinary()
  const runtimeDetection = await detectRoachNetContainerRuntime({
    commandPath,
    commandExists: commandResponds,
    runProcess: runCommand,
  })
  const useContainerlessRuntime =
    wantsContainerlessRuntime(envValues) ||
    !runtimeDetection.dockerCliPath ||
    runtimeDetection.daemonRunning === false

  if (useContainerlessRuntime) {
    debugBoot('launch-server:containerless-mode', {
      requested: wantsContainerlessRuntime(envValues),
      dockerCliAvailable: Boolean(runtimeDetection.dockerCliPath),
      dockerDaemonRunning: runtimeDetection.daemonRunning ?? null,
    })
  } else {
    await ensureManagedSupportServices(envValues, timeoutMs)
  }
  debugBoot('launch-server:support-ready', {
    targetKind: target.kind,
    containerless: useContainerlessRuntime,
  })
  const buildRuntimeOptions = {
    forceContainerless: useContainerlessRuntime,
  }
  const resolvedTarget =
    target.kind === 'build' ? await prepareBuildRuntimeTarget(envValues, buildRuntimeOptions) : target
  const runtimeEnvValues =
    resolvedTarget?.kind === 'build' || resolvedTarget?.kind === 'source'
      ? getBuildRuntimeEnvValues(envValues, buildRuntimeOptions)
      : getRuntimeEnvValues(envValues)

  if (!resolvedTarget) {
    debugBoot('launch-server:resolved-target-missing', {
      targetKind: target.kind,
    })
    return {
      child: null,
      childExited: true,
      healthyUrl: null,
      target,
    }
  }

  const childEnv = {
    ...process.env,
    ...runtimeEnvValues,
    NODE_ENV: resolvedTarget.kind === 'build' ? 'production' : envValues.NODE_ENV || 'development',
    ROACHNET_REPO_ROOT: repoRoot,
  }

  debugBoot('launch-server:spawn-server', {
    resolvedKind: resolvedTarget.kind,
    resolvedEntrypoint: resolvedTarget.entrypoint,
    cwd: resolvedTarget.cwd,
  })

  const serverHandle = spawnDetachedNodeProcess({
    nodeBinary,
    runtimeKind: resolvedTarget.kind,
    entrypoint: resolvedTarget.entrypoint,
    args: resolvedTarget.args ?? [],
    cwd: resolvedTarget.cwd,
    env: childEnv,
    logFd: serverLogFd,
  })

  const runtimeRoot =
    resolvedTarget.kind === 'build'
      ? path.dirname(path.dirname(resolvedTarget.entrypoint))
      : resolvedTarget.cwd

  if (resolvedTarget.kind === 'build') {
    try {
      await ensureBuildRuntimeDatabaseReady(runtimeRoot, runtimeEnvValues)
    } catch (error) {
      if (!serverHandle.hasExited()) {
        terminateDetachedChild(serverHandle.child)
      }

      clearRuntimeProcessInfo(runtimeEnvValues)
      throw error
    }
  }

  const workerEntrypoint =
    resolvedTarget.kind === 'build'
      ? path.join(runtimeRoot, 'bin', 'worker.js')
      : path.join(runtimeRoot, 'bin', 'worker.ts')
  let workerHandle = null
  let ollamaHandle = null
  let openclawHandle = null
  let companionHandle = null
  let companionUrl = null
  let companionAdvertisedUrl = null

  if (existsSync(workerEntrypoint)) {
    if (runtimeEnvValues.ROACHNET_DISABLE_QUEUE === '1') {
      debugBoot('launch-server:skip-worker', {
        workerEntrypoint,
        reason: 'queue-disabled',
      })
    } else {
      debugBoot('launch-server:spawn-worker', {
        workerEntrypoint,
      })
      workerHandle = spawnDetachedNodeProcess({
        nodeBinary,
        runtimeKind: resolvedTarget.kind,
        entrypoint: workerEntrypoint,
        cwd: resolvedTarget.cwd,
        env: childEnv,
        logFd: serverLogFd,
      })
    }
  }

  const healthyUrl = await waitForHealth(healthUrls, timeoutMs, {
    exitWhen: () => serverHandle.hasExited(),
    exitGraceMs: EXITED_SERVER_HEALTH_GRACE_MS,
  })
  debugBoot('launch-server:health-result', {
    resolvedKind: resolvedTarget.kind,
    healthyUrl: healthyUrl?.toString() ?? null,
    serverExited: serverHandle.hasExited(),
    workerExited: workerHandle?.hasExited() ?? null,
  })
  if (healthyUrl) {
    if (wantsContainerlessRuntime(runtimeEnvValues)) {
      ollamaHandle = await maybeSpawnContainedOllama({
        runtimeEnvValues,
        logFd: serverLogFd,
      })

      if (runtimeEnvValues.OLLAMA_BASE_URL?.trim()) {
        const ollamaHealthUrl = new URL('/api/version', runtimeEnvValues.OLLAMA_BASE_URL).toString()
        void waitForHttpEndpoint(ollamaHealthUrl, Math.min(timeoutMs, 120_000)).then((ollamaReady) => {
          if (!ollamaReady) {
            console.warn(
              `Contained Ollama did not answer on ${runtimeEnvValues.OLLAMA_BASE_URL} before the local timeout. ` +
                'RoachClaw may stay unavailable until Ollama finishes warming up.'
            )
          }
        })
      }
    }

    openclawHandle = await maybeSpawnOpenClawGateway({
      runtimeEnvValues,
      logFd: serverLogFd,
    })

    const companionTargetUrl = resolveCompanionTargetUrl({
      resolvedTarget,
      healthyUrl,
    })
    const companion = await maybeSpawnCompanionServer({
      nodeBinary,
      runtimeEnvValues,
      targetUrl: companionTargetUrl,
      logFd: serverLogFd,
    })
    companionHandle = companion.handle
    companionUrl = companion.localUrl
    companionAdvertisedUrl = companion.advertisedUrl

    recordDetachedRuntimeChildren({
      target: resolvedTarget,
      serverHandle,
      workerHandle,
      ollamaHandle,
      openclawHandle,
      companionHandle,
      companionUrl,
      companionAdvertisedUrl,
    })

    return {
      child: serverHandle.child,
      childExited: serverHandle.hasExited(),
      worker: workerHandle?.child ?? null,
      companion: companionHandle?.child ?? null,
      companionUrl,
      companionAdvertisedUrl,
      healthyUrl,
      target: resolvedTarget,
    }
  }

  if (!serverHandle.hasExited()) {
    terminateDetachedChild(serverHandle.child)
  }

  if (workerHandle && !workerHandle.hasExited()) {
    terminateDetachedChild(workerHandle.child)
  }

  if (ollamaHandle && !ollamaHandle.hasExited()) {
    terminateDetachedChild(ollamaHandle.child)
  }

  if (openclawHandle && !openclawHandle.hasExited()) {
    terminateDetachedChild(openclawHandle.child)
  }

  if (companionHandle && !companionHandle.hasExited()) {
    terminateDetachedChild(companionHandle.child)
  }

  clearRuntimeProcessInfo(envValues)

  return {
    child: serverHandle.child,
    childExited: serverHandle.hasExited(),
    worker: workerHandle?.child ?? null,
    healthyUrl: null,
    target: resolvedTarget,
  }
}

async function main() {
  const envValues = await loadEnv()
  const runtimeEnvValues = getRuntimeEnvValues(envValues)
  process.env.NOMAD_STORAGE_PATH = runtimeEnvValues.NOMAD_STORAGE_PATH
  process.env.OPENCLAW_WORKSPACE_PATH = runtimeEnvValues.OPENCLAW_WORKSPACE_PATH
  process.env.OLLAMA_MODELS = runtimeEnvValues.OLLAMA_MODELS
  process.env.ROACHNET_CONTAINERLESS_MODE = runtimeEnvValues.ROACHNET_CONTAINERLESS_MODE
  process.env.ROACHNET_DISABLE_QUEUE = runtimeEnvValues.ROACHNET_DISABLE_QUEUE
  process.env.ROACHNET_INSTALL_PROFILE = process.env.ROACHNET_INSTALL_PROFILE || runtimeEnvValues.ROACHNET_INSTALL_PROFILE || ''
  process.env.ROACHNET_LOCAL_BIN_PATH = envValues.ROACHNET_LOCAL_BIN_PATH || getLocalBinRoot()
  if (envValues.ROACHNET_NODE_BINARY) {
    process.env.ROACHNET_NODE_BINARY = envValues.ROACHNET_NODE_BINARY
  }
  if (envValues.ROACHNET_NPM_BINARY) {
    process.env.ROACHNET_NPM_BINARY = envValues.ROACHNET_NPM_BINARY
  }
  process.env.PATH = [
    process.env.ROACHNET_LOCAL_BIN_PATH,
    path.dirname(getPreferredNodeBinary()),
    process.env.PATH || '',
  ]
    .filter(Boolean)
    .join(path.delimiter)
  debugBoot('main:start', {
    argv: process.argv.slice(2),
  })

  if (process.argv.includes('--stop')) {
    await stopManagedRuntime(envValues)
    debugBoot('main:stopped')
    console.log('RoachNet runtime stopped.')
    return
  }
  const baseUrl = getBaseUrl(envValues)
  const healthUrls = getLoopbackHealthUrls(baseUrl, envValues)
  const requestedOpenPath = getRequestedOpenPath()

  const alreadyRunningUrl = await waitForHealth(healthUrls, 1_000)
  debugBoot('main:already-running-check', {
    alreadyRunningUrl: alreadyRunningUrl?.toString() ?? null,
  })

  if (alreadyRunningUrl) {
    const runningHomeUrl = await getPreferredPublicUrl(new URL(requestedOpenPath, alreadyRunningUrl), envValues)
    writeServerInfo({
      pid: null,
      healthUrl: alreadyRunningUrl.toString(),
      webUrl: runningHomeUrl.toString(),
      companionUrl: getCompanionLocalUrl(runtimeEnvValues),
      companionAdvertisedUrl: getCompanionAdvertisedUrl(runtimeEnvValues),
      target: 'existing',
      repoRoot,
    })
    openBrowser(runningHomeUrl.toString())
    console.log(`RoachNet is already running at ${runningHomeUrl.toString()}`)
    return
  }

  const storageLogsDir = getStorageLogsDir(runtimeEnvValues)
  const serverLogPath = getServerLogPath(runtimeEnvValues)
  mkdirSync(storageLogsDir, { recursive: true })

  const trackedInfo = readRuntimeProcessInfo(runtimeEnvValues)
  await terminateManagedRuntimeProcesses([
    trackedInfo?.serverPid,
    trackedInfo?.workerPid,
    trackedInfo?.ollamaPid,
    trackedInfo?.openclawPid,
    trackedInfo?.companionPid,
  ])
  clearRuntimeProcessInfo(runtimeEnvValues)

  const serverLogFd = openSync(serverLogPath, 'a')
  const preferredTarget = getServerRuntimeTarget()
  const sourceFallbackTarget = getSourceRuntimeTarget()
  const sourceFallbackAvailable = canRunSourceRuntime(sourceFallbackTarget)

  let launchResult

  try {
    launchResult = await launchServer(
      preferredTarget,
      envValues,
      healthUrls,
      preferredTarget.kind === 'build' ? BUILD_BOOT_TIMEOUT_MS : SERVER_BOOT_TIMEOUT_MS,
      serverLogFd
    )
  } catch (error) {
    debugBoot('main:launch-error', {
      message: error.message,
      targetKind: preferredTarget.kind,
    })
    if (preferredTarget.kind !== 'build' || process.env.ROACHNET_USE_SOURCE === '1') {
      throw error
    }

    console.log(
      `Compiled RoachNet runtime failed before it became healthy. Falling back to the source server...\n${error.message}`
    )
    launchResult = {
      child: null,
      childExited: true,
      healthyUrl: null,
      target: preferredTarget,
    }
  }

  if (!launchResult.healthyUrl && preferredTarget.kind === 'build' && process.env.ROACHNET_USE_SOURCE !== '1') {
    const recoveredHealthUrl = await waitForHealth(healthUrls, EXISTING_RUNTIME_RECONNECT_GRACE_MS)

    if (recoveredHealthUrl) {
      debugBoot('main:recovered-existing-runtime', {
        recoveredHealthUrl: recoveredHealthUrl.toString(),
      })
      launchResult = {
        child: null,
        childExited: false,
        healthyUrl: recoveredHealthUrl,
        target: preferredTarget,
      }
    } else if (sourceFallbackAvailable) {
      debugBoot('main:fallback-to-source')
      console.log('Compiled RoachNet runtime did not become healthy. Falling back to the source server...')
      launchResult = await launchServer(
        sourceFallbackTarget,
        envValues,
        healthUrls,
        SERVER_BOOT_TIMEOUT_MS,
        serverLogFd
      )
    } else {
      debugBoot('main:skip-source-fallback', {
        sourceEntrypoint: sourceFallbackTarget.entrypoint,
      })
      console.warn(
        'Compiled RoachNet runtime did not become healthy and no runnable source fallback is bundled with this install.'
      )
    }
  }

  if (!launchResult.healthyUrl) {
    const reason = launchResult.childExited
      ? 'The RoachNet server exited before it became healthy.'
      : 'The RoachNet server did not become healthy before the startup timeout.'
    throw new Error(`${reason} Check ${serverLogPath} for startup logs.`)
  }

  const homeUrl = await getPreferredPublicUrl(new URL(requestedOpenPath, launchResult.healthyUrl), envValues)

  writeServerInfo({
    pid: launchResult.child?.pid ?? null,
    healthUrl: launchResult.healthyUrl.toString(),
    webUrl: homeUrl.toString(),
    companionUrl: launchResult.companionUrl ?? null,
    companionAdvertisedUrl: launchResult.companionAdvertisedUrl ?? null,
    target: launchResult.target.kind,
    repoRoot,
    logPath: serverLogPath,
  })

  openBrowser(homeUrl.toString())

  console.log(`RoachNet server started.`)
  console.log(`Server runtime: ${launchResult.target.kind}`)
  console.log(`Server entrypoint: ${launchResult.target.entrypoint}`)
  console.log(`Web UI: ${homeUrl.toString()}`)
  console.log(`Server logs: ${serverLogPath}`)
}

main().catch((error) => {
  debugBoot('main:unhandled-error', {
    message: error.message,
  })
  console.error(error.message)
  process.exitCode = 1
})
