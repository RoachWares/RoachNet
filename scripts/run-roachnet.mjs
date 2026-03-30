#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, openSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { cp, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import {
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
const storageLogsDir = path.join(adminDir, 'storage', 'logs')
const serverLogPath = path.join(storageLogsDir, 'roachnet-server.log')
const runtimeCacheRoot = path.join(tmpdir(), 'roachnet-runtime-cache')
const managementComposePath = path.join(repoRoot, 'ops', 'roachnet-management.compose.yml')

const SERVER_BOOT_TIMEOUT_MS = 180_000
const BUILD_BOOT_TIMEOUT_MS = 60_000
const HEALTH_POLL_INTERVAL_MS = 1_500
const HEALTH_REQUEST_TIMEOUT_MS = 3_000
const BUILD_RUNTIME_METADATA_FILENAME = '.roachnet-runtime.json'
const BUILD_RUNTIME_DEPENDENCY_STAMP_FILENAME = '.roachnet-lock-hash'

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

function getPreferredNodeBinary() {
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/node'
  return existsSync(macHomebrewNode22) ? macHomebrewNode22 : process.execPath
}

function getPersistentStorageRoot() {
  return path.join(adminDir, 'storage')
}

function getRuntimeEnvValues(envValues) {
  const storageRoot = envValues.NOMAD_STORAGE_PATH?.trim() || getPersistentStorageRoot()

  return {
    ...envValues,
    NOMAD_STORAGE_PATH: storageRoot,
    OPENCLAW_WORKSPACE_PATH:
      envValues.OPENCLAW_WORKSPACE_PATH?.trim() || path.join(storageRoot, 'openclaw'),
  }
}

function getServerRuntimeTarget() {
  if (existsSync(managementComposePath)) {
    return {
      cwd: repoRoot,
      entrypoint: managementComposePath,
      kind: 'docker',
    }
  }

  if (process.env.ROACHNET_USE_SOURCE === '1') {
    return {
      cwd: adminDir,
      entrypoint: 'bin/server.js',
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

  return {
    cwd: adminDir,
    entrypoint: 'bin/server.js',
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

function getBuildRuntimeFingerprint() {
  if (!existsSync(buildEntrypointPath) || !existsSync(buildPackageLockPath) || !existsSync(buildPackageJsonPath)) {
    return null
  }

  const buildLockfile = readFileSync(buildPackageLockPath, 'utf8')
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
  const runtimeEnvValues = getRuntimeEnvValues(envValues)
  const fingerprint = getBuildRuntimeFingerprint()

  if (!fingerprint) {
    return null
  }

  const runtimeDir = path.join(runtimeCacheRoot, fingerprint.signature.slice(0, 16))
  const runtimeMetadataPath = path.join(runtimeDir, BUILD_RUNTIME_METADATA_FILENAME)
  const runtimeNodeModulesPath = path.join(runtimeDir, 'node_modules')
  const runtimeDependencyStampPath = path.join(
    runtimeNodeModulesPath,
    BUILD_RUNTIME_DEPENDENCY_STAMP_FILENAME
  )
  const existingSignature = existsSync(runtimeMetadataPath)
    ? JSON.parse(readFileSync(runtimeMetadataPath, 'utf8')).signature
    : null
  const hasStagedEntrypoint = existsSync(path.join(runtimeDir, 'bin', 'server.js'))

  mkdirSync(runtimeCacheRoot, { recursive: true })

  if (!hasStagedEntrypoint || existingSignature !== fingerprint.signature) {
    console.log('Staging the compiled RoachNet runtime outside the workspace...')
    rmSync(runtimeDir, { recursive: true, force: true })

    await cp(buildDir, runtimeDir, {
      recursive: true,
      force: true,
      dereference: false,
      filter(source) {
        return path.basename(source) !== 'node_modules'
      },
    })

    writeFileSync(
      runtimeMetadataPath,
      JSON.stringify({ signature: fingerprint.signature }, null, 2) + '\n',
      'utf8'
    )
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
  }

  return {
    cwd: adminDir,
    entrypoint: path.join(runtimeDir, 'bin', 'server.js'),
    kind: 'build',
  }
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

async function launchServer(target, envValues, healthUrls, timeoutMs, serverLogFd) {
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
  const resolvedTarget =
    target.kind === 'build' ? await prepareBuildRuntimeTarget(envValues) : target
  const runtimeEnvValues = getRuntimeEnvValues(envValues)

  if (!resolvedTarget) {
    return {
      child: null,
      childExited: true,
      healthyUrl: null,
      target,
    }
  }

  const child = spawn(
    nodeBinary,
    resolvedTarget.kind === 'source'
      ? [
          '--import=ts-node-maintained/register/esm',
          '--enable-source-maps',
          '--disable-warning=ExperimentalWarning',
          resolvedTarget.entrypoint,
        ]
      : [resolvedTarget.entrypoint],
    {
      cwd: resolvedTarget.cwd,
      detached: true,
      env: {
        ...process.env,
        ...runtimeEnvValues,
        NODE_ENV: resolvedTarget.kind === 'build' ? 'production' : envValues.NODE_ENV || 'development',
        ROACHNET_REPO_ROOT: repoRoot,
      },
      stdio: ['ignore', serverLogFd, serverLogFd],
    }
  )

  let childExited = false
  child.on('exit', () => {
    childExited = true
  })
  child.unref()

  const healthyUrl = await waitForHealth(healthUrls, timeoutMs)
  if (healthyUrl) {
    return {
      child,
      childExited,
      healthyUrl,
      target: resolvedTarget,
    }
  }

  if (!childExited) {
    terminateDetachedChild(child)
  }

  return {
    child,
    childExited,
    healthyUrl: null,
    target: resolvedTarget,
  }
}

async function main() {
  const envValues = await loadEnv()
  const baseUrl = getBaseUrl(envValues)
  const healthUrls = getLoopbackHealthUrls(baseUrl)
  const requestedOpenPath = getRequestedOpenPath()

  const alreadyRunningUrl = await waitForHealth(healthUrls, 1_000)

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
    console.log('Compiled RoachNet runtime did not become healthy. Falling back to the source server...')
    launchResult = await launchServer(
      {
        cwd: adminDir,
        entrypoint: 'bin/server.js',
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
  console.error(error.message)
  process.exitCode = 1
})
