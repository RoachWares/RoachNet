import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { requestHttp } from '../lib/roachnet_http.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(__dirname, '..', '..')
const nativeBinary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const requiresNativeBinary = nativeBinary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

function buildFakeInstallerAssets(root) {
  const assets = path.join(root, 'RoachNet Setup.app', 'Contents', 'Resources', 'InstallerAssets')
  const app = path.join(assets, 'RoachNet.app')
  mkdirSync(path.join(app, 'Contents', 'Helpers'), { recursive: true })
  mkdirSync(path.join(app, 'Contents', 'MacOS'), { recursive: true })
  cpSync(nativeBinary, path.join(app, 'Contents', 'Helpers', 'roachnet-runtime'))
  chmodSync(path.join(app, 'Contents', 'Helpers', 'roachnet-runtime'), 0o755)
  const dataRoot = path.join(app, 'Contents', 'Resources', 'RoachNetRuntimeData')
  cpSync(path.join(repoRoot, 'collections'), path.join(dataRoot, 'collections'), { recursive: true })
  writeFileSync(path.join(app, 'Contents', 'MacOS', 'RoachNetApp'), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
  writeFileSync(path.join(assets, 'setup-assets.marker'), '')
  const ollamaPayload = path.join(root, 'ollama-payload')
  mkdirSync(ollamaPayload, { recursive: true })
  writeFileSync(path.join(ollamaPayload, 'ollama'), '#!/bin/sh\necho "ollama version 0.0.0-test"\n', { mode: 0o755 })
  const tar = spawnSync('tar', ['-czf', path.join(assets, 'bundled-ollama.tar.gz'), '-C', ollamaPayload, '.'])
  assert.equal(tar.status, 0, String(tar.stderr))
  return assets
}

async function startSetup(env) {
  const readyFile = path.join(env.HOME, 'setup-ready.json')
  const child = spawn(nativeBinary, ['--setup'], { env: { ...env, ROACHNET_SETUP_READY_FILE: readyFile }, stdio: 'ignore' })
  const deadline = Date.now() + 15_000
  while (Date.now() < deadline) {
    if (existsSync(readyFile)) {
      const { url } = JSON.parse(readFileSync(readyFile, 'utf8'))
      return { child, url }
    }
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  child.kill('SIGKILL')
  throw new Error('setup service did not become ready')
}

async function call(url, method = 'GET', body) {
  const response = await requestHttp(url, {
    method,
    headers: { Accept: 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    timeoutMs: 10_000,
  })
  return { status: response.status, body: JSON.parse(await response.text()) }
}

async function runInstall(url, config) {
  const started = await call(`${url}/api/install`, 'POST', config)
  assert.equal(started.status, 200, JSON.stringify(started.body))
  const deadline = Date.now() + 90_000
  while (Date.now() < deadline) {
    const state = await call(`${url}/api/state`)
    if (!state.body.activeTask && state.body.lastCompletedTask) {
      return state.body
    }
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
  throw new Error('install did not finish')
}

test('native setup installs, verifies, and upgrades RoachNet without Node', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-test-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
    ROACHNET_INSTALLER_CONFIG_PATH: path.join(home, 'installer.json'),
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
    ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
    ROACHNET_REQUIRE_LOCAL_ALIAS: '1',
  }
  writeFileSync(env.ROACHNET_HOSTS_FILE, '127.0.0.1 localhost\n::1 localhost\n')
  const installPath = path.join(home, 'RoachNet')
  const { child, url } = await startSetup(env)
  try {
    const initial = await call(`${url}/api/state`)
    assert.equal(initial.status, 200)
    assert.equal(initial.body.system.runtime, 'native-swift')
    assert.equal(initial.body.installLooksReady, false)
    assert.equal(initial.body.dependencies.some((dependency) => dependency.id === 'disk-space'), true)
    assert.equal(initial.body.containerRuntime.available, false)

    const docker = await call(`${url}/api/container-runtime/start`, 'POST', {})
    assert.equal(docker.status, 400)

    const first = await runInstall(url, { installPath, autoLaunch: false, installRoachClaw: true })
    assert.equal(first.lastCompletedTask.status, 'completed', JSON.stringify(first.lastCompletedTask))
    assert.equal(first.installLooksReady, true)
    assert.equal(first.nativeApp.installed, true)
    assert.equal(existsSync(path.join(installPath, 'app', 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')), true)
    assert.equal(existsSync(path.join(installPath, 'roachnet-install.json')), true)
    assert.equal(lstatSync(path.join(installPath, 'bin', 'ollama')).isSymbolicLink(), true)
    assert.equal(readlinkSync(path.join(installPath, 'bin', 'ollama')), '../runtime/vendor/ollama/ollama')
    assert.equal(existsSync(path.join(installPath, 'runtime', 'vendor', 'ollama', 'ollama')), true)
    assert.equal(first.lastCompletedTask.logs.some((line) => /health check/.test(line)), true)
    assert.equal(
      readFileSync(env.ROACHNET_HOSTS_FILE, 'utf8'),
      '127.0.0.1 localhost\n::1 localhost\n\n# >>> RoachNet local alias >>>\n127.0.0.1 RoachNet\n::1 RoachNet\n# <<< RoachNet local alias <<<\n'
    )
    const savedConfig = JSON.parse(readFileSync(env.ROACHNET_INSTALLER_CONFIG_PATH, 'utf8'))
    assert.equal(typeof savedConfig.setupCompletedAt, 'string')
    assert.equal(savedConfig.pendingRoachClawSetup, true)

    // Upgrade over the existing install: user storage must survive the swap.
    const userFile = path.join(installPath, 'storage', 'Vault', 'keep-me.md')
    mkdirSync(path.dirname(userFile), { recursive: true })
    writeFileSync(userFile, '# survives upgrades\n')
    // Homebrew keeps RoachNet Setup inside the root; user files may sit there too.
    const brewSetupMarker = path.join(installPath, 'setup', 'RoachNet Setup.app', 'Contents', 'Info.plist')
    mkdirSync(path.dirname(brewSetupMarker), { recursive: true })
    writeFileSync(brewSetupMarker, '<plist/>\n')
    writeFileSync(path.join(installPath, 'notes.txt'), 'mine\n')
    const second = await runInstall(url, { installPath, autoLaunch: false, installRoachClaw: true })
    assert.equal(second.lastCompletedTask.status, 'completed', JSON.stringify(second.lastCompletedTask))
    assert.equal(readFileSync(userFile, 'utf8'), '# survives upgrades\n')
    assert.equal(readFileSync(brewSetupMarker, 'utf8'), '<plist/>\n')
    assert.equal(readFileSync(path.join(installPath, 'notes.txt'), 'utf8'), 'mine\n')
    // Re-running setup must not duplicate the alias block.
    assert.equal(readFileSync(env.ROACHNET_HOSTS_FILE, 'utf8').match(/RoachNet local alias >>>/g).length, 1)
    const siblings = spawnSync('ls', [home]).stdout.toString()
    assert.doesNotMatch(siblings, /RoachNet\.(backup|staging)-/)
  } finally {
    child.kill('SIGTERM')
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('native setup refuses an install with no app payload and leaves no staging behind', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-fail-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(tempRoot, 'missing', 'InstallerAssets'),
    ROACHNET_INSTALLER_CONFIG_PATH: path.join(home, 'installer.json'),
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
  }
  const { child, url } = await startSetup(env)
  try {
    const result = await runInstall(url, { installPath: path.join(home, 'RoachNet'), autoLaunch: false, installRoachClaw: false })
    assert.equal(result.lastCompletedTask.status, 'failed')
    assert.match(result.lastCompletedTask.error, /could not find the RoachNet app payload/)
    assert.equal(existsSync(path.join(home, 'RoachNet')), false)
    const siblings = spawnSync('ls', [home]).stdout.toString()
    assert.doesNotMatch(siblings, /staging/)
  } finally {
    child.kill('SIGTERM')
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('roachnet-runtime --install performs a headless install for Homebrew and scripted lanes', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-headless-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  try {
    const result = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], {
      env: {
        PATH: process.env.PATH,
        HOME: home,
        ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
        ROACHNET_INSTALLER_CONFIG_PATH: path.join(home, 'installer.json'),
        ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
        ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
        ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
      },
      encoding: 'utf8',
      timeout: 90_000,
    })
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stdout, /Phase: Verifying contained runtime/)
    assert.match(result.stdout, /RoachNet installed at/)
    assert.equal(existsSync(path.join(installPath, 'app', 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')), true)
    assert.equal(existsSync(path.join(installPath, 'bin', 'ollama')), false)
    // Missing hosts file is best effort unless ROACHNET_REQUIRE_LOCAL_ALIAS=1.
    assert.match(result.stdout, /RoachTail local alias could not be provisioned automatically/)
    const savedConfig = JSON.parse(readFileSync(path.join(home, 'installer.json'), 'utf8'))
    assert.equal(savedConfig.pendingRoachClawSetup, false)
  } finally {
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('native setup recovers from an install that was killed mid-upgrade', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-recover-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  // A previous run moved the root aside and died before the staged copy landed.
  const backupRoot = path.join(home, 'RoachNet.backup-1700000000000')
  mkdirSync(path.join(backupRoot, 'storage', 'Vault'), { recursive: true })
  writeFileSync(path.join(backupRoot, 'storage', 'Vault', 'precious.md'), 'keep\n')
  mkdirSync(path.join(home, 'RoachNet.staging-deadbeef', 'app'), { recursive: true })
  try {
    const result = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], {
      env: {
        PATH: process.env.PATH,
        HOME: home,
        ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
        ROACHNET_INSTALLER_CONFIG_PATH: path.join(home, 'installer.json'),
        ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
        ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
      },
      encoding: 'utf8',
      timeout: 90_000,
    })
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stdout, /Removed an unfinished staged install/)
    assert.match(result.stdout, /Restored the previous install/)
    assert.equal(readFileSync(path.join(installPath, 'storage', 'Vault', 'precious.md'), 'utf8'), 'keep\n')
    assert.doesNotMatch(spawnSync('ls', [home]).stdout.toString(), /RoachNet\.(backup|staging)-/)
  } finally {
    await rm(tempRoot, { recursive: true, force: true })
  }
})
