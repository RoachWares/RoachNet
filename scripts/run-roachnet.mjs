#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { cp, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import {
  composeDownRoachNetServices,
  composeUpRoachNetServices,
  detectRoachNetContainerRuntime,
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
const storageLogsDir = path.join(adminDir, 'storage', 'logs')
const serverLogPath = path.join(storageLogsDir, 'roachnet-server.log')
const launcherDebugLogPath = path.join(storageLogsDir, 'roachnet-launcher-debug.log')
const runtimeProcessInfoPath = path.join(storageLogsDir, 'roachnet-runtime-processes.json')
const runtimeCacheRoot = path.join(tmpdir(), 'roachnet-runtime-cache')
const managementComposePath = path.join(repoRoot, 'ops', 'roachnet-management.compose.yml')

const SERVER_BOOT_TIMEOUT_MS = 300_000
const BUILD_BOOT_TIMEOUT_MS = 300_000
const HEALTH_POLL_INTERVAL_MS = 1_500
const HEALTH_REQUEST_TIMEOUT_MS = 3_000
const BUILD_RUNTIME_METADATA_FILENAME = '.roachnet-runtime.json'
const BUILD_RUNTIME_DEPENDENCY_STAMP_FILENAME = '.roachnet-lock-hash'
const BUILD_RUNTIME_MYSQL_PORT = '33306'
const BUILD_RUNTIME_REDIS_PORT = '36379'
const BUILD_RUNTIME_QDRANT_PORT = '36333'
const BUILD_RUNTIME_OLLAMA_PORT = '36434'
const BUILD_RUNTIME_OPENCLAW_PORT = '13001'
const MANAGED_RUNTIME_DB_USER = 'nomad_user'
const MANAGED_RUNTIME_DB_PASSWORD = '7154b9bbb511df8d89c1e1417d8427e3'
const MANAGED_RUNTIME_DB_DATABASE = 'nomad'

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

function getPreferredNpmBinary() {
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/npm'
  return existsSync(macHomebrewNode22) ? macHomebrewNode22 : 'npm'
}

function hashString(value) {
  return createHash('sha256').update(value).digest('hex')
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

function getLoopbackHealthUrls(baseUrl) {
  const urls = [new URL('/api/health', baseUrl)]
  const hostname = baseUrl.hostname.replace(/^\[|\]$/g, '')
  const protocol = baseUrl.protocol
  const port = baseUrl.port
  const pathName = '/api/health'

  if (hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1') {
    const hostCandidates = ['localhost', '127.0.0.1', '[::1]']

    for (const candidate of hostCandidates) {
      const candidateUrl = new URL(`${protocol}//${candidate}${port ? `:${port}` : ''}${pathName}`)
      if (!urls.some((url) => url.toString() === candidateUrl.toString())) {
        urls.push(candidateUrl)
      }
    }
  }

  return urls
}

async function waitForHealth(urls, timeoutMs) {
  const startedAt = Date.now()

  while (Date.now() - startedAt < timeoutMs) {
    for (const url of urls) {
      const abortController = new AbortController()
      const timeout = setTimeout(() => abortController.abort(), HEALTH_REQUEST_TIMEOUT_MS)

      try {
        const response = await fetch(url, {
          headers: { Accept: 'application/json' },
          signal: abortController.signal,
        })

        if (response.ok) {
          clearTimeout(timeout)
          return url
        }
      } catch {
        // Server is still booting or another loopback host is in use.
      } finally {
        clearTimeout(timeout)
      }
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
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/node'
  return existsSync(macHomebrewNode22) ? macHomebrewNode22 : process.execPath
}

function debugBoot(stage, details = {}) {
  if (process.env.ROACHNET_DEBUG_BOOT !== '1') {
    return
  }

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

  if (process.platform === 'darwin' && process.env.HOME) {
    return path.join(process.env.HOME, 'Library', 'Application Support', 'roachnet', 'runtime-state')
  }

  return path.join(getRuntimeEnvValues(envValues).NOMAD_STORAGE_PATH, 'runtime-state')
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

  return {
    ...envValues,
    NOMAD_STORAGE_PATH: storageRoot,
    ROACHNET_MANIFESTS_BASE_URL: manifestsBaseUrl,
    OPENCLAW_WORKSPACE_PATH:
      configuredOpenClawWorkspace ? path.resolve(configuredOpenClawWorkspace) : path.join(storageRoot, 'openclaw'),
  }
}

function getBuildRuntimeEnvValues(envValues) {
  const runtimeValues = getRuntimeEnvValues(envValues)

  return {
    ...runtimeValues,
    HOST: '127.0.0.1',
    PORT: '8080',
    URL: 'http://127.0.0.1:8080',
    DB_HOST: '127.0.0.1',
    DB_PORT: BUILD_RUNTIME_MYSQL_PORT,
    DB_DATABASE: MANAGED_RUNTIME_DB_DATABASE,
    DB_USER: MANAGED_RUNTIME_DB_USER,
    DB_PASSWORD: MANAGED_RUNTIME_DB_PASSWORD,
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

  return {
    ...process.env,
    ...runtimeValues,
    ROACHNET_REPO_ROOT: repoRoot,
    ROACHNET_HOST_STORAGE_PATH: storageRoot,
    ROACHNET_RUNTIME_STATE_ROOT: getManagedRuntimeStateRoot(envValues),
  }
}

function getServerRuntimeTarget() {
  if (process.env.ROACHNET_USE_SOURCE === '1') {
    return {
      cwd: adminDir,
      entrypoint: 'ace.js',
      args: ['serve', '--assets=false'],
      kind: 'source',
    }
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

  return {
    cwd: adminDir,
    entrypoint: 'ace.js',
    args: ['serve', '--assets=false'],
    kind: 'source',
  }
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

  writeFileSync(outputPath, JSON.stringify(info, null, 2) + '\n', 'utf8')
}

function writeRuntimeProcessInfo(info) {
  mkdirSync(storageLogsDir, { recursive: true })
  writeFileSync(runtimeProcessInfoPath, JSON.stringify(info, null, 2) + '\n', 'utf8')
}

function readRuntimeProcessInfo() {
  if (!existsSync(runtimeProcessInfoPath)) {
    return null
  }

  try {
    return JSON.parse(readFileSync(runtimeProcessInfoPath, 'utf8'))
  } catch {
    return null
  }
}

function clearRuntimeProcessInfo() {
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

  await composeUpRoachNetServices({
    composeFiles: [managementComposePath],
    cwd: repoRoot,
    installPath: repoRoot,
    runProcess: runCommand,
    env: getManagedRuntimeEnvValues(envValues),
    waitTimeoutMs: timeoutMs,
    services: ['mysql', 'redis', 'qdrant', 'ollama'],
  })

  const ollamaReady = await waitForHttpEndpoint(
    `http://127.0.0.1:${BUILD_RUNTIME_OLLAMA_PORT}/api/version`,
    Math.min(timeoutMs, 120_000)
  )

  debugBoot('managed-support:ready', {
    runtimeStateRoot: getManagedRuntimeStateRoot(envValues),
    ollamaReady,
  })

  if (!ollamaReady) {
    console.warn(
      `Contained Ollama did not answer on :${BUILD_RUNTIME_OLLAMA_PORT} before the support timeout. ` +
        'RoachNet will continue booting, but local chat may remain unavailable until Ollama finishes warming up.'
    )
  }
}

async function stopManagedRuntime(envValues) {
  const trackedInfo = readRuntimeProcessInfo()
  await terminateManagedRuntimeProcesses([
    trackedInfo?.serverPid,
    trackedInfo?.workerPid,
    trackedInfo?.openclawPid,
  ])

  if (!existsSync(managementComposePath)) {
    clearRuntimeProcessInfo()
    return
  }

  try {
    await composeDownRoachNetServices({
      composeFiles: [managementComposePath],
      cwd: repoRoot,
      installPath: repoRoot,
      runProcess: runCommand,
      env: getManagedRuntimeEnvValues(envValues),
    })
  } catch {
    // Containers may already be down.
  }

  clearRuntimeProcessInfo()
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

async function prepareBuildRuntimeTarget(envValues) {
  const runtimeEnvValues = getBuildRuntimeEnvValues(envValues)
  const fingerprint = getBuildRuntimeFingerprint()

  if (!fingerprint) {
    debugBoot('build-runtime:fingerprint-missing')
    return null
  }

  debugBoot('build-runtime:fingerprint-ready', {
    dependencyHash: fingerprint.dependencyHash,
    signature: fingerprint.signature,
  })

  const runtimeDir = path.join(runtimeCacheRoot, fingerprint.signature.slice(0, 16))
  const runtimeMetadataPath = path.join(runtimeDir, BUILD_RUNTIME_METADATA_FILENAME)
  const runtimeNodeModulesPath = path.join(runtimeDir, 'node_modules')
  const runtimeDependencyStampPath = path.join(runtimeDir, BUILD_RUNTIME_DEPENDENCY_STAMP_FILENAME)
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

  const installedHash = existsSync(runtimeDependencyStampPath)
    ? readFileSync(runtimeDependencyStampPath, 'utf8').trim()
    : ''
  const hasCoreDependency = existsSync(path.join(runtimeNodeModulesPath, '@adonisjs', 'core'))

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
        PATH: `/opt/homebrew/opt/node@22/bin:${process.env.PATH || ''}`,
      },
    })

    writeFileSync(runtimeDependencyStampPath, `${fingerprint.dependencyHash}\n`, 'utf8')
    debugBoot('build-runtime:install-deps-ready', {
      runtimeDir,
    })
  }

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

  const consoleEnv = {
    ...process.env,
    ...runtimeEnvValues,
    NODE_ENV: 'production',
    ROACHNET_DISABLE_TRANSMIT: '1',
    PATH: `/opt/homebrew/opt/node@22/bin:${process.env.PATH || ''}`,
  }
  const nodeBinary = getPreferredNodeBinary()

  debugBoot('build-runtime:db-bootstrap:start', {
    runtimeRoot,
  })
  console.log('Preparing the compiled RoachNet database...')

  await runCommand(nodeBinary, [consoleEntrypoint, 'migration:run', '--force'], {
    cwd: runtimeRoot,
    env: consoleEnv,
  })

  await runCommand(nodeBinary, [consoleEntrypoint, 'db:seed'], {
    cwd: runtimeRoot,
    env: consoleEnv,
  })

  debugBoot('build-runtime:db-bootstrap:ready', {
    runtimeRoot,
  })
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

function recordDetachedRuntimeChildren({ target, serverHandle, workerHandle, openclawHandle }) {
  writeRuntimeProcessInfo({
    targetKind: target.kind,
    targetEntrypoint: target.entrypoint,
    serverPid: serverHandle.child?.pid ?? null,
    workerPid: workerHandle?.child?.pid ?? null,
    openclawPid: openclawHandle?.child?.pid ?? null,
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
  const npxBinary = await commandPath('npx')
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

  if (!npxBinary) {
    return null
  }

  return spawnDetachedProcess({
    binary: npxBinary,
    args: [
      '-y',
      'openclaw',
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
      installPath: repoRoot,
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
  await ensureManagedSupportServices(envValues, timeoutMs)
  debugBoot('launch-server:support-ready', {
    targetKind: target.kind,
  })
  const resolvedTarget =
    target.kind === 'build' ? await prepareBuildRuntimeTarget(envValues) : target
  const runtimeEnvValues =
    resolvedTarget?.kind === 'build' || resolvedTarget?.kind === 'source'
      ? getBuildRuntimeEnvValues(envValues)
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
    await ensureBuildRuntimeDatabaseReady(runtimeRoot, runtimeEnvValues)
  }

  const workerEntrypoint =
    resolvedTarget.kind === 'build'
      ? path.join(runtimeRoot, 'bin', 'worker.js')
      : path.join(runtimeRoot, 'bin', 'worker.entry.js')
  let workerHandle = null
  let openclawHandle = null

  if (existsSync(workerEntrypoint)) {
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

  openclawHandle = await maybeSpawnOpenClawGateway({
    runtimeEnvValues,
    logFd: serverLogFd,
  })

  recordDetachedRuntimeChildren({
    target: resolvedTarget,
    serverHandle,
    workerHandle,
    openclawHandle,
  })

  const healthyUrl = await waitForHealth(healthUrls, timeoutMs)
  debugBoot('launch-server:health-result', {
    resolvedKind: resolvedTarget.kind,
    healthyUrl: healthyUrl?.toString() ?? null,
    serverExited: serverHandle.hasExited(),
    workerExited: workerHandle?.hasExited() ?? null,
  })
  if (healthyUrl) {
    return {
      child: serverHandle.child,
      childExited: serverHandle.hasExited(),
      worker: workerHandle?.child ?? null,
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

  if (openclawHandle && !openclawHandle.hasExited()) {
    terminateDetachedChild(openclawHandle.child)
  }

  clearRuntimeProcessInfo()

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
  const healthUrls = getLoopbackHealthUrls(baseUrl)
  const requestedOpenPath = getRequestedOpenPath()

  const alreadyRunningUrl = await waitForHealth(healthUrls, 1_000)
  debugBoot('main:already-running-check', {
    alreadyRunningUrl: alreadyRunningUrl?.toString() ?? null,
  })

  if (alreadyRunningUrl) {
    const runningHomeUrl = new URL(requestedOpenPath, alreadyRunningUrl)
    writeServerInfo({
      pid: null,
      healthUrl: alreadyRunningUrl.toString(),
      webUrl: runningHomeUrl.toString(),
      target: 'existing',
      repoRoot,
    })
    openBrowser(runningHomeUrl.toString())
    console.log(`RoachNet is already running at ${runningHomeUrl.toString()}`)
    return
  }

  mkdirSync(storageLogsDir, { recursive: true })

  const trackedInfo = readRuntimeProcessInfo()
  await terminateManagedRuntimeProcesses([
    trackedInfo?.serverPid,
    trackedInfo?.workerPid,
    trackedInfo?.openclawPid,
  ])
  clearRuntimeProcessInfo()

  const serverLogFd = openSync(serverLogPath, 'a')
  const preferredTarget = getServerRuntimeTarget()

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
    debugBoot('main:fallback-to-source')
    console.log('Compiled RoachNet runtime did not become healthy. Falling back to the source server...')
    launchResult = await launchServer(
      {
        cwd: adminDir,
        entrypoint: 'ace.js',
        args: ['serve', '--assets=false'],
        kind: 'source',
      },
      envValues,
      healthUrls,
      SERVER_BOOT_TIMEOUT_MS,
      serverLogFd
    )
  }

  if (!launchResult.healthyUrl) {
    const reason = launchResult.childExited
      ? 'The RoachNet server exited before it became healthy.'
      : 'The RoachNet server did not become healthy before the startup timeout.'
    throw new Error(`${reason} Check ${serverLogPath} for startup logs.`)
  }

  const homeUrl = new URL(requestedOpenPath, launchResult.healthyUrl)

  writeServerInfo({
    pid: launchResult.child?.pid ?? null,
    healthUrl: launchResult.healthyUrl.toString(),
    webUrl: homeUrl.toString(),
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
