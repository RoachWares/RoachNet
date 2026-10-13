import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { chmodSync, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
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
  // A stale runner payload from an older Setup build: 1.1 setup must ignore it.
  const ollamaPayload = path.join(root, 'ollama-payload')
  mkdirSync(ollamaPayload, { recursive: true })
  writeFileSync(path.join(ollamaPayload, 'ollama'), '#!/bin/sh\necho "ollama version 0.0.0-test"\n', { mode: 0o755 })
  const tar = spawnSync('tar', ['-czf', path.join(assets, 'bundled-ollama.tar.gz'), '-C', ollamaPayload, '.'])
  assert.equal(tar.status, 0, String(tar.stderr))
  return assets
}

async function startSetup(env) {
  const readyFile = path.join(env.HOME, 'setup-ready.json')
  // A service that was stopped mid-install leaves its ready file behind.
  rmSync(readyFile, { force: true })
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

// The choices on the Setup app's screen: the saved config, with an install
// folder (and anything else) picked.
function choicesFor(configPath, folder, overrides = {}) {
  return {
    ...JSON.parse(readFileSync(configPath, 'utf8')),
    installPath: folder,
    installedAppPath: path.join(folder, 'app', 'RoachNet.app'),
    storagePath: path.join(folder, 'storage'),
    autoLaunch: false,
    installRoachClaw: false,
    ...overrides,
  }
}

// What Open in the Setup app does before it opens RoachNet, and what any
// client of the setup service can do: save the choices through /api/config.
async function saveChoices(url, configPath, folder, overrides = {}) {
  const choices = choicesFor(configPath, folder, overrides)
  const saved = await call(`${url}/api/config`, 'POST', choices)
  assert.equal(saved.status, 200, JSON.stringify(saved.body))
  return choices
}

// What the Setup app's Install button does: it sends the choices with the
// install and saves nothing first.
async function installFromApp(url, configPath, folder, overrides = {}) {
  return runInstall(url, choicesFor(configPath, folder, overrides))
}

// Ends a Setup service the way a power cut or a force quit would (SIGKILL),
// or as quitting Setup does (SIGTERM), and waits until it is gone.
async function stopSetup(service, signal) {
  const exited = new Promise((resolve) => service.child.once('exit', resolve))
  service.child.kill(signal)
  await exited
}

// The same, from a Setup service that ROACHNET_SETUP_TEST_STOP_AT ends during
// the install as a power cut would. Resolves with the service's exit code.
async function installFromAppUntilStopped(service, configPath, folder, overrides = {}) {
  const exited = new Promise((resolve) => service.child.once('exit', resolve))
  const started = await call(`${service.url}/api/install`, 'POST', choicesFor(configPath, folder, overrides))
  assert.equal(started.status, 200, JSON.stringify(started.body))
  let timer
  const timeout = new Promise((resolve, reject) => {
    timer = setTimeout(() => reject(new Error('the install did not stop')), 90_000)
  })
  try {
    return await Promise.race([exited, timeout])
  } finally {
    clearTimeout(timer)
  }
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
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
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
    // No model runner is installed: RoachClaw uses the native RoachInference engine.
    assert.equal(existsSync(path.join(installPath, 'bin', 'ollama')), false)
    assert.equal(existsSync(path.join(installPath, 'runtime', 'vendor', 'ollama')), false)
    assert.equal(first.lastCompletedTask.logs.some((line) => /native RoachInference engine/.test(line)), true)
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
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
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

test('native setup refuses an app payload without a usable runtime helper and keeps the installed copy', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-nohelper-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  const configPath = path.join(home, 'installer.json')
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
    ROACHNET_INSTALLER_CONFIG_PATH: configPath,
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
    ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
  }
  const install = () =>
    spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
  const payloadHelper = path.join(assets, 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')
  const restoreHelper = () => {
    rmSync(payloadHelper, { recursive: true, force: true })
    cpSync(nativeBinary, payloadHelper)
    chmodSync(payloadHelper, 0o755)
  }
  try {
    const first = install()
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`)
    const installedHelper = path.join(installPath, 'app', 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')
    const helperBefore = readFileSync(installedHelper)
    const configBefore = JSON.parse(readFileSync(configPath, 'utf8'))
    const userFile = path.join(installPath, 'storage', 'Vault', 'keep-me.md')
    mkdirSync(path.dirname(userFile), { recursive: true })
    writeFileSync(userFile, 'mine\n')

    // The app starts its runtime only through the helper. Each of these
    // payloads is refused before anything is replaced: the installed app and
    // its helper, the person's files and the saved settings stay as they
    // were, and no staged copy is left behind.
    const unusable = [
      ['missing', () => rmSync(payloadHelper), /no usable runtime helper/],
      ['not executable', () => chmodSync(payloadHelper, 0o644), /no usable runtime helper/],
      ['a folder', () => { rmSync(payloadHelper); mkdirSync(payloadHelper) }, /no usable runtime helper/],
      ['a link', () => { rmSync(payloadHelper); symlinkSync(nativeBinary, payloadHelper) }, /no usable runtime helper/],
      ['a program that fails', () => { rmSync(payloadHelper); writeFileSync(payloadHelper, '#!/bin/sh\nexit 3\n', { mode: 0o755 }) }, /exited during verification \(status 3\)/],
    ]
    for (const [label, breakHelper, expected] of unusable) {
      breakHelper()
      const result = install()
      assert.notEqual(result.status, 0, `${label}: ${result.stdout}`)
      assert.match(result.stderr, expected, label)
      assert.doesNotMatch(result.stdout, /Skipped runtime verification/, label)
      assert.equal(readFileSync(installedHelper).equals(helperBefore), true, `${label}: installed helper changed`)
      assert.equal(readFileSync(userFile, 'utf8'), 'mine\n', label)
      assert.deepEqual(JSON.parse(readFileSync(configPath, 'utf8')), configBefore, `${label}: saved settings changed`)
      assert.doesNotMatch(spawnSync('ls', [home]).stdout.toString(), /RoachNet\.(backup|staging)-/, label)
      restoreHelper()
    }

    // A failed install into another folder doesn't point the saved settings there.
    rmSync(payloadHelper)
    const elsewhere = path.join(home, 'RoachNet-elsewhere')
    const moved = spawnSync(nativeBinary, ['--install', '--install-path', elsewhere, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.notEqual(moved.status, 0, moved.stdout)
    assert.deepEqual(JSON.parse(readFileSync(configPath, 'utf8')), configBefore, 'another folder: saved settings changed')
    assert.equal(existsSync(elsewhere), false)
    assert.doesNotMatch(spawnSync('ls', [home]).stdout.toString(), /staging-/)
    restoreHelper()

    // With a usable helper back in place, the same payload installs again.
    const again = install()
    assert.equal(again.status, 0, `${again.stdout}\n${again.stderr}`)
    assert.equal(readFileSync(userFile, 'utf8'), 'mine\n')
  } finally {
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('a failed install keeps the installed copy\'s settings, even when new choices were saved first', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-app-flow-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  const elsewhere = path.join(home, 'RoachNet-elsewhere')
  const configPath = path.join(home, 'installer.json')
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
    ROACHNET_INSTALLER_CONFIG_PATH: configPath,
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
    ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
  }
  const payloadHelper = path.join(assets, 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')
  const restoreHelper = () => {
    rmSync(payloadHelper, { recursive: true, force: true })
    cpSync(nativeBinary, payloadHelper)
    chmodSync(payloadHelper, 0o755)
  }
  const savedConfig = () => JSON.parse(readFileSync(configPath, 'utf8'))
  let service
  try {
    const first = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`)
    const installed = savedConfig()
    assert.equal(typeof installed.setupCompletedAt, 'string')

    // Setup opens over the finished install, and the payload has lost its
    // helper. A client saves new choices before it asks for the install.
    service = await startSetup(env)
    rmSync(payloadHelper)
    await saveChoices(service.url, configPath, elsewhere)
    const failed = await installFromApp(service.url, configPath, elsewhere)
    assert.equal(failed.lastCompletedTask.status, 'failed')
    assert.match(failed.lastCompletedTask.error, /no usable runtime helper/)
    assert.equal(savedConfig().installPath, installPath, 'the saved settings describe the copy that is still installed')
    assert.equal(savedConfig().setupCompletedAt, installed.setupCompletedAt)
    assert.equal(existsSync(path.join(installPath, 'app', 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')), true)
    assert.equal(existsSync(elsewhere), false)
    assert.doesNotMatch(spawnSync('ls', [home]).stdout.toString(), /staging-/)

    // An install that works moves the remembered settings along with it.
    restoreHelper()
    const moved = await installFromApp(service.url, configPath, elsewhere)
    assert.equal(moved.lastCompletedTask.status, 'completed', JSON.stringify(moved.lastCompletedTask))
    const movedConfig = savedConfig()
    assert.equal(movedConfig.installPath, elsewhere)
    rmSync(payloadHelper)
    const back = await installFromApp(service.url, configPath, installPath)
    assert.equal(back.lastCompletedTask.status, 'failed')
    assert.equal(savedConfig().installPath, elsewhere, 'the settings of the latest finished install come back')
    assert.equal(savedConfig().setupCompletedAt, movedConfig.setupCompletedAt)
  } finally {
    service?.child.kill('SIGTERM')
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('after an install that fails past its swap, a later failed install keeps the new copy\'s settings', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-post-swap-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  const elsewhere = path.join(home, 'RoachNet-elsewhere')
  const configPath = path.join(home, 'installer.json')
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
    ROACHNET_INSTALLER_CONFIG_PATH: configPath,
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
    ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
  }
  const savedConfig = () => JSON.parse(readFileSync(configPath, 'utf8'))
  let service
  try {
    const first = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`)

    // The local alias is required and its hosts file can't be written, so an
    // install fails after its swap: the new copy is in place, set up or not.
    const brokenHosts = path.join(tempRoot, 'hosts-is-a-folder')
    mkdirSync(brokenHosts)
    service = await startSetup({ ...env, ROACHNET_HOSTS_FILE: brokenHosts, ROACHNET_REQUIRE_LOCAL_ALIAS: '1' })
    const pastSwap = await installFromApp(service.url, configPath, elsewhere)
    assert.equal(pastSwap.lastCompletedTask.status, 'failed', JSON.stringify(pastSwap.lastCompletedTask))
    assert.equal(existsSync(path.join(elsewhere, 'app', 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')), true)
    assert.equal(savedConfig().installPath, elsewhere)

    // A retry that fails before its swap puts back the new copy's settings.
    rmSync(path.join(assets, 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime'))
    const beforeSwap = await installFromApp(service.url, configPath, installPath)
    assert.equal(beforeSwap.lastCompletedTask.status, 'failed')
    assert.match(beforeSwap.lastCompletedTask.error, /no usable runtime helper/)
    assert.equal(savedConfig().installPath, elsewhere, 'the settings describe the copy installed last')
  } finally {
    service?.child.kill('SIGTERM')
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('Setup puts back an upgrade cut off mid-swap before reading the install, so a failed retry keeps its settings', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-cut-off-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  const configPath = path.join(home, 'installer.json')
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
    ROACHNET_INSTALLER_CONFIG_PATH: configPath,
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
    ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
  }
  const payloadHelper = path.join(assets, 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')
  const savedConfig = () => JSON.parse(readFileSync(configPath, 'utf8'))
  // Where an upgrade stops if power is lost between moving the install aside and moving the new one in.
  const cutOff = () => renameSync(installPath, `${installPath}.backup-20261013-000000`)
  let service
  try {
    const first = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`)
    const installed = savedConfig()
    assert.equal(typeof installed.setupCompletedAt, 'string')
    rmSync(payloadHelper)

    // In the Setup app.
    cutOff()
    service = await startSetup(env)
    assert.equal(existsSync(path.join(installPath, 'app', 'RoachNet.app')), true, 'Setup put the install back when it started')
    const failed = await installFromApp(service.url, configPath, installPath)
    assert.equal(failed.lastCompletedTask.status, 'failed')
    for (const key of ['installPath', 'setupCompletedAt', 'pendingLaunchIntro', 'pendingRoachClawSetup']) {
      assert.deepEqual(savedConfig()[key], installed[key], `app: ${key}`)
    }
    service.child.kill('SIGTERM')
    service = undefined

    // From the command line.
    cutOff()
    const retried = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.notEqual(retried.status, 0, retried.stdout)
    assert.equal(existsSync(path.join(installPath, 'app', 'RoachNet.app')), true)
    for (const key of ['installPath', 'setupCompletedAt', 'pendingLaunchIntro', 'pendingRoachClawSetup']) {
      assert.deepEqual(savedConfig()[key], installed[key], `command line: ${key}`)
    }
  } finally {
    service?.child.kill('SIGTERM')
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('an upgrade cut off before its copy is in place gives the installed copy its settings back, though it saved new ones', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-pre-upgrade-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  const elsewhere = path.join(home, 'RoachNet-elsewhere')
  const movedStorage = path.join(home, 'RoachNet-storage')
  const configPath = path.join(home, 'installer.json')
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
    ROACHNET_INSTALLER_CONFIG_PATH: configPath,
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
    ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
  }
  const payloadHelper = path.join(assets, 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')
  const savedConfig = () => JSON.parse(readFileSync(configPath, 'utf8'))
  const keptAside = `${configPath}.pre-upgrade`
  const stoppingAt = (point) => ({ ...env, ROACHNET_SETUP_TEST_STOP_AT: point })
  let service
  try {
    const first = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`)
    const installed = savedConfig()
    assert.equal(typeof installed.setupCompletedAt, 'string')

    // An upgrade in place that moves storage loses power between moving the
    // installed copy aside and moving the new one in.
    service = await startSetup(stoppingAt('moved-aside'))
    assert.equal(await installFromAppUntilStopped(service, configPath, installPath, { storagePath: movedStorage }), 75)
    service = undefined
    assert.equal(existsSync(installPath), false, 'the installed copy is aside')
    assert.equal(savedConfig().storagePath, movedStorage, 'the upgrade saved its choices first')
    service = await startSetup(env)
    assert.equal(existsSync(path.join(installPath, 'app', 'RoachNet.app')), true, 'Setup put the install back')
    for (const key of ['installPath', 'storagePath', 'setupCompletedAt', 'pendingLaunchIntro']) {
      assert.deepEqual(savedConfig()[key], installed[key], `in place: ${key}`)
    }
    assert.equal(existsSync(keptAside), false)
    service.child.kill('SIGTERM')
    service = undefined

    // A move to another folder is cut off before its copy lands. The command
    // line retries it with a payload that fails before its swap.
    service = await startSetup(stoppingAt('swap'))
    assert.equal(await installFromAppUntilStopped(service, configPath, elsewhere), 75)
    service = undefined
    assert.equal(savedConfig().installPath, elsewhere)
    rmSync(payloadHelper)
    const retried = spawnSync(nativeBinary, ['--install', '--install-path', elsewhere, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.notEqual(retried.status, 0, retried.stdout)
    assert.match(retried.stdout, /Put back the saved settings of the copy that is installed/)
    for (const key of ['installPath', 'storagePath', 'setupCompletedAt', 'pendingLaunchIntro']) {
      assert.deepEqual(savedConfig()[key], installed[key], `moved: ${key}`)
    }
    assert.equal(existsSync(elsewhere), false)
    assert.equal(existsSync(keptAside), false)
    cpSync(nativeBinary, payloadHelper)
    chmodSync(payloadHelper, 0o755)

    // A move cut off once its copy is in place keeps that copy's settings.
    service = await startSetup(stoppingAt('moved-in'))
    assert.equal(await installFromAppUntilStopped(service, configPath, elsewhere), 75)
    service = await startSetup(env)
    assert.equal(existsSync(path.join(elsewhere, 'app', 'RoachNet.app')), true)
    assert.equal(savedConfig().installPath, elsewhere, 'the copy that landed keeps its settings')
    assert.equal(existsSync(keptAside), false)
  } finally {
    service?.child.kill('SIGTERM')
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('saved choices that would move the installed copy give way to its settings unless an install puts them in place', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-saved-choices-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  const movedStorage = path.join(home, 'RoachNet-storage')
  const configPath = path.join(home, 'installer.json')
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
    ROACHNET_INSTALLER_CONFIG_PATH: configPath,
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
    ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
  }
  const savedConfig = () => JSON.parse(readFileSync(configPath, 'utf8'))
  const keptAside = `${configPath}.pre-upgrade`
  const keys = ['installPath', 'installedAppPath', 'storagePath', 'setupCompletedAt']
  let service
  try {
    const first = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`)
    const installed = savedConfig()

    // A new storage folder is saved, and Setup is killed before any install.
    service = await startSetup(env)
    await saveChoices(service.url, configPath, installPath, { storagePath: movedStorage })
    assert.equal(savedConfig().storagePath, movedStorage)
    assert.equal(existsSync(keptAside), true, 'the installed copy\'s settings were kept aside first')
    await stopSetup(service, 'SIGKILL')
    service = await startSetup(env)
    for (const key of keys) assert.deepEqual(savedConfig()[key], installed[key], `after the kill: ${key}`)
    assert.equal(existsSync(keptAside), false)
    await stopSetup(service, 'SIGTERM')

    // A choice that leaves the installed copy where it is stays as saved.
    service = await startSetup(env)
    await saveChoices(service.url, configPath, installPath, { companionPort: 38999 })
    assert.equal(existsSync(keptAside), false)
    await stopSetup(service, 'SIGKILL')
    service = await startSetup(env)
    assert.equal(savedConfig().companionPort, 38999)
    await stopSetup(service, 'SIGTERM')

    // When the settings can't be put back, they stay aside for the next run.
    service = await startSetup(env)
    await saveChoices(service.url, configPath, installPath, { storagePath: movedStorage })
    await stopSetup(service, 'SIGKILL')
    const pending = readFileSync(configPath, 'utf8')
    rmSync(configPath)
    mkdirSync(configPath)
    writeFileSync(path.join(configPath, 'in-the-way'), '')
    service = await startSetup(env)
    assert.equal(existsSync(keptAside), true, 'kept while the config can\'t be written')
    await stopSetup(service, 'SIGTERM')
    rmSync(configPath, { recursive: true, force: true })
    writeFileSync(configPath, pending)
    service = await startSetup(env)
    for (const key of keys) assert.deepEqual(savedConfig()[key], installed[key], `once it can be written: ${key}`)
    assert.equal(existsSync(keptAside), false)
  } finally {
    service?.child.kill('SIGTERM')
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('Setup changes nothing about the installed copy when it can\'t keep that copy\'s settings aside', requiresNativeBinary, async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'rn-native-setup-cant-keep-'))
  const home = path.join(tempRoot, 'home')
  mkdirSync(home, { recursive: true })
  const assets = buildFakeInstallerAssets(tempRoot)
  const installPath = path.join(home, 'RoachNet')
  const movedStorage = path.join(home, 'RoachNet-storage')
  const configPath = path.join(home, 'installer.json')
  const env = {
    PATH: process.env.PATH,
    HOME: home,
    ROACHNET_SETUP_APP_BUNDLE: path.join(assets, 'setup-assets.marker'),
    ROACHNET_INSTALLER_CONFIG_PATH: configPath,
    ROACHNET_SETUP_ALLOW_UNSUPPORTED_HOST: '1',
    ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
    ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
    ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
  }
  const savedConfig = () => JSON.parse(readFileSync(configPath, 'utf8'))
  const keptAside = `${configPath}.pre-upgrade`
  let service
  try {
    const first = spawnSync(nativeBinary, ['--install', '--install-path', installPath, '--no-roachclaw'], { env, encoding: 'utf8', timeout: 90_000 })
    assert.equal(first.status, 0, `${first.stdout}\n${first.stderr}`)
    const installed = savedConfig()

    // Someone's folder sits where Setup keeps the installed copy's settings.
    mkdirSync(keptAside)
    writeFileSync(path.join(keptAside, 'notes.txt'), 'keep\n')
    service = await startSetup(env)
    const refused = await call(`${service.url}/api/config`, 'POST', choicesFor(configPath, installPath, { storagePath: movedStorage }))
    assert.equal(refused.status, 400, JSON.stringify(refused.body))
    assert.match(refused.body.error, /couldn't keep the installed copy's settings aside/)
    const failed = await installFromApp(service.url, configPath, installPath, { storagePath: movedStorage })
    assert.equal(failed.lastCompletedTask.status, 'failed')
    assert.match(failed.lastCompletedTask.error, /couldn't keep the installed copy's settings aside/)
    for (const key of ['installPath', 'installedAppPath', 'storagePath', 'setupCompletedAt']) {
      assert.deepEqual(savedConfig()[key], installed[key], key)
    }
    assert.equal(readFileSync(path.join(keptAside, 'notes.txt'), 'utf8'), 'keep\n', 'the folder is left alone')
    assert.equal(existsSync(path.join(installPath, 'app', 'RoachNet.app', 'Contents', 'Helpers', 'roachnet-runtime')), true)
    assert.doesNotMatch(spawnSync('ls', [home]).stdout.toString(), /RoachNet\.(staging|backup)-/)
  } finally {
    service?.child.kill('SIGTERM')
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
        ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
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
        ROACHNET_SETUP_TEST_MIN_FREE_BYTES: String(256 * 1024 * 1024),
        ROACHNET_STORAGE_PATH: path.join(tempRoot, 'setup-logs'),
        // Without it the install edits /etc/hosts, which prompts for an admin
        // password: a CI runner waits out the timeout, and a Mac that already
        // has the alias passes only by luck.
        ROACHNET_HOSTS_FILE: path.join(tempRoot, 'hosts'),
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
