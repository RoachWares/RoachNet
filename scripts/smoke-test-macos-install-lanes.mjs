#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { cp, mkdtemp, rm } from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const distRoot = path.join(repoRoot, 'native', 'macos', 'dist')
const setupBundlePath = path.join(distRoot, 'RoachNet Setup.app')
const packagedAppBundlePath = path.join(setupBundlePath, 'Contents', 'Resources', 'InstallerAssets', 'RoachNet.app')
const packageVersion = JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8')).version || '1.0.0'
const pollIntervalMs = 1_500
const startupTimeoutMs = 300_000
const keepTempArtifacts = process.env.ROACHNET_SMOKE_KEEP_TEMP === '1'

function assert(condition, message) {
  if (!condition) {
    throw new Error(message)
  }
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

function getPackagedSetupRuntimePaths() {
  return {
    nodeBinary: path.join(setupBundlePath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node', 'bin', 'node'),
    launcherPath: path.join(setupBundlePath, 'Contents', 'Resources', 'RoachNetSource', 'scripts', 'run-roachnet-setup.mjs'),
  }
}

function getPackagedAppRuntimePaths(appBundlePath) {
  return {
    nodeBinary: path.join(appBundlePath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node', 'bin', 'node'),
    launcherPath: path.join(appBundlePath, 'Contents', 'Resources', 'RoachNetSource', 'scripts', 'run-roachnet.mjs'),
    aliasInstallerPath: path.join(appBundlePath, 'Contents', 'Resources', 'RoachNetSource', 'scripts', 'install-roachtail-hostname.mjs'),
    envPath: path.join(appBundlePath, 'Contents', 'Resources', 'RoachNetSource', 'admin', '.env'),
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

  return {
    ...baseShellEnv(homePath),
    NOMAD_STORAGE_PATH: storagePath,
    OPENCLAW_WORKSPACE_PATH: path.join(storagePath, 'openclaw'),
    OLLAMA_MODELS: path.join(storagePath, 'ollama'),
    OLLAMA_BASE_URL: 'http://127.0.0.1:36434',
    OPENCLAW_BASE_URL: 'http://127.0.0.1:13001',
    ROACHNET_RUNTIME_STATE_ROOT: path.join(storagePath, 'state', 'runtime-state'),
    ROACHNET_LOCAL_BIN_PATH: path.join(installRoot, 'bin'),
    ROACHNET_NODE_BINARY: runtime.nodeBinary,
    ROACHNET_NPM_BINARY: path.join(path.dirname(runtime.nodeBinary), 'npm'),
    ROACHNET_INSTALL_PROFILE: installProfile,
    ROACHNET_BOOTSTRAP_PENDING: config.bootstrapPending ? '1' : '0',
    ROACHNET_CONTAINERLESS_MODE: containerlessMode,
    ROACHNET_DISABLE_QUEUE: containerlessMode === '1' ? '1' : '0',
    ROACHNET_ROACHCLAW_DEFAULT_MODEL: config.roachClawDefaultModel || 'qwen2.5-coder:1.5b',
    ROACHNET_INSTALLER_CONFIG_PATH: extra.ROACHNET_INSTALLER_CONFIG_PATH,
    ...extra,
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
      const response = await fetch(url, {
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

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
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

async function verifyBundleVersions() {
  const bundles = [
    ['RoachNet', path.join(distRoot, 'RoachNet.app')],
    ['RoachNet Setup', setupBundlePath],
    ['InstallerAssets RoachNet', packagedAppBundlePath],
  ]

  for (const [label, bundlePath] of bundles) {
    assert(existsSync(bundlePath), `Missing ${label} bundle at ${bundlePath}`)
    const version = readBundleVersion(bundlePath)
    assert(
      version === packageVersion,
      `${label} bundle version mismatch. Expected ${packageVersion}, found ${version || 'missing'} at ${bundlePath}`
    )
  }
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

async function smokeSetupLane() {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-setup-smoke-'))
  const homePath = path.join(tempRoot, 'home')
  const sharedAppDataDir = path.join(homePath, 'Library', 'Application Support', 'roachnet')
  const configPath = path.join(sharedAppDataDir, 'roachnet-installer.json')
  const installRoot = path.join(tempRoot, 'installed', 'RoachNet')
  const installAppPath = path.join(installRoot, 'app', 'RoachNet.app')
  const storagePath = path.join(installRoot, 'storage')
  const { nodeBinary, launcherPath } = getPackagedSetupRuntimePaths()
  const setupPort = await resolveAvailablePort()
  const setupBaseUrl = `http://127.0.0.1:${setupPort}`
  const mockHostsPath = path.join(tempRoot, 'mock-hosts')

  mkdirSync(homePath, { recursive: true })
  mkdirSync(path.join(homePath, 'tmp'), { recursive: true })
  mkdirSync(path.dirname(installRoot), { recursive: true })
  writeFileSync(mockHostsPath, '127.0.0.1 localhost\n::1 localhost\n', 'utf8')

  const setupProcess = spawnProcess(nodeBinary, [launcherPath], {
    cwd: path.dirname(launcherPath),
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
    await waitForHttpOk(new URL('/api/state', setupBaseUrl).toString(), startupTimeoutMs)

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

    const task = await waitForSetupTask(setupBaseUrl)
    assert(task.result?.appPath === installAppPath, 'Setup lane completed without the expected app target path.')
    assert(existsSync(installAppPath), `Setup lane did not install the native app at ${installAppPath}`)
    assert(existsSync(path.join(installRoot, 'scripts', 'run-roachnet.mjs')), 'Setup lane did not promote the contained runtime tree.')
    assert(
      readFileSync(mockHostsPath, 'utf8').includes('127.0.0.1 RoachNet'),
      withTaskLogs(
        'Setup lane did not provision the RoachTail local alias in the mock hosts file.',
        task
      )
    )

    const installedRuntime = getPackagedAppRuntimePaths(installAppPath)
    const installedEnvValues = parseEnvFile(readFileSync(installedRuntime.envPath, 'utf8'))
    const runtimeStateRoot = path.join(storagePath, 'state', 'runtime-state')
    const launcher = spawnProcess(installedRuntime.nodeBinary, [installedRuntime.launcherPath], {
      cwd: path.dirname(installedRuntime.launcherPath),
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
          ROACHNET_NO_BROWSER: '1',
          ROACHNET_INSTALLER_CONFIG_PATH: configPath,
          ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
        },
      }),
    })

    try {
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
        const stopProcess = spawnProcess(installedRuntime.nodeBinary, [installedRuntime.launcherPath, '--stop'], {
          cwd: path.dirname(installedRuntime.launcherPath),
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
  } catch (error) {
    const processLogs = formatProcessLogs('setup backend', setupProcess.getLogs())
    throw new Error([error.message, processLogs].filter(Boolean).join('\n\n'))
  } finally {
    await stopChild(setupProcess.child)
    await safeRemoveTree(tempRoot)
  }
}

async function smokeHomebrewLane() {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-homebrew-smoke-'))
  const homePath = path.join(tempRoot, 'home')
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

  await cp(packagedAppBundlePath, appPath, {
    recursive: true,
    force: true,
  })

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

  const runtime = getPackagedAppRuntimePaths(appPath)
  const aliasInstaller = spawnProcess(runtime.nodeBinary, [runtime.aliasInstallerPath, '--apply'], {
    cwd: path.dirname(runtime.aliasInstallerPath),
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

  const envValues = parseEnvFile(readFileSync(runtime.envPath, 'utf8'))
  const healthUrl = new URL('/api/health', envValues.URL || 'http://127.0.0.1:8080').toString()
  const runtimeStateRoot = path.join(storagePath, 'state', 'runtime-state')

  const launcher = spawnProcess(runtime.nodeBinary, [runtime.launcherPath], {
    cwd: path.dirname(runtime.launcherPath),
    env: buildContainedRuntimeEnv({
      homePath,
      installRoot,
      storagePath,
      runtime,
      config,
      extra: {
        ROACHNET_NO_BROWSER: '1',
        ROACHNET_INSTALLER_CONFIG_PATH: configPath,
        ROACHNET_RUNTIME_STATE_ROOT: runtimeStateRoot,
      },
    }),
  })

  try {
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
    try {
      const stopProcess = spawnProcess(runtime.nodeBinary, [runtime.launcherPath, '--stop'], {
        cwd: path.dirname(runtime.launcherPath),
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
      // Ignore shutdown errors in cleanup.
    }

    await stopChild(launcher.child)
    await safeRemoveTree(tempRoot)
  }
}

async function main() {
  assert(process.platform === 'darwin', 'This smoke test only runs on macOS.')
  await verifyBundleVersions()
  await smokeSetupLane()
  await smokeHomebrewLane()
  console.log('RoachNet macOS setup and Homebrew install lanes are healthy.')
}

main().catch((error) => {
  console.error(error.message)
  process.exitCode = 1
})
