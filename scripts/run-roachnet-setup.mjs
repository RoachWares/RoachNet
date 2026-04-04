#!/usr/bin/env node

import http from 'node:http'
import { spawn } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { chmod, copyFile, cp, mkdtemp, readFile, readdir, rename, rm, stat } from 'node:fs/promises'
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
const GITHUB_API_ROOT = 'https://api.github.com'
const DEFAULT_ROACHCLAW_MODEL = 'qwen2.5-coder:1.5b'

const runtimeState = {
  task: null,
  lastCompletedTask: null,
  persistedConfig: null,
  diagnosticsCache: {
    value: null,
    expiresAt: 0,
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
  }
}

function stripUndefinedEntries(input) {
  return Object.fromEntries(Object.entries(input).filter(([, value]) => value !== undefined))
}

function loadPersistedInstallerConfig() {
  if (runtimeState.persistedConfig) {
    return runtimeState.persistedConfig
  }

  const configPath = getInstallerConfigPath()
  const legacyConfigPath = getLegacyInstallerConfigPath()
  const primaryConfig = readJsonFile(configPath)
  const legacyConfig = configPath === legacyConfigPath ? null : readJsonFile(legacyConfigPath)

  runtimeState.persistedConfig = primaryConfig || legacyConfig || {}

  if (!primaryConfig && legacyConfig) {
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

function getLocalArtifactDescriptor(version = getCurrentAppVersion()) {
  const arch = process.arch
  const setupBundlePath = process.env.ROACHNET_SETUP_APP_BUNDLE
  const setupBundleDir = setupBundlePath ? path.dirname(setupBundlePath) : null
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
        path.join(repoRoot, 'desktop-dist', `RoachNet-${version}-mac-${arch}.zip`),
        path.join(repoRoot, 'native', 'macos', 'dist', `RoachNet-${version}-mac-${arch}.zip`),
        setupBundleDir ? path.join(setupBundleDir, `RoachNet-${version}-mac-${arch}.zip`) : null,
      ].filter(Boolean),
      assetMatcher(name) {
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
      return name.includes(`linux-${arch}`) && name.endsWith('.AppImage')
    },
  }
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    headers: {
      Accept: 'application/vnd.github+json, application/json',
      'User-Agent': 'RoachNet-Setup',
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
    await runProcess('ditto', ['--noqtn', sourcePath, targetPath], {
      env: getShellEnv(),
    })
  } else {
    await cp(sourcePath, targetPath, {
      recursive: true,
      force: true,
    })
  }
  await clearMacQuarantine(targetPath)
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

  const shellTargetPath = escapeForSingleQuotedShell(targetPath)
  const clearCommand = `
if [ -e '${shellTargetPath}' ]; then
  xattr -cr '${shellTargetPath}' >/dev/null 2>&1 || true
fi
`.trim()

  await runShell(clearCommand, { env: getShellEnv() }).catch(() => {})
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
  const downloadDirectory = await mkdtemp(path.join(os.tmpdir(), 'roachnet-app-download-'))
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
    const extractionRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-app-extract-'))
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
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    let stdout = ''
    let stderr = ''
    let timedOut = false
    const timeoutHandle =
      timeoutMs > 0
        ? setTimeout(() => {
            timedOut = true
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

function escapeForSingleQuotedShell(value) {
  return String(value).replace(/'/g, `'\"'\"'`)
}

function buildPrivilegedShellCommand(command) {
  const shellCommand = `/bin/zsh -lc '${escapeForSingleQuotedShell(command)}'`

  if (process.platform === 'darwin') {
    const appleScript = `do shell script "${shellCommand.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}" with administrator privileges`
    return {
      binary: 'osascript',
      args: ['-e', appleScript],
    }
  }

  if (process.platform === 'win32') {
    return {
      binary: 'powershell',
      args: [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        `Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',"${shellCommand.replaceAll('"', '`"')}"`,
      ],
    }
  }

  if (existsSync('/usr/bin/pkexec')) {
    return {
      binary: '/usr/bin/pkexec',
      args: ['/bin/sh', '-lc', command],
    }
  }

  return {
    binary: '/usr/bin/sudo',
    args: ['/bin/sh', '-lc', command],
  }
}

async function runPrivilegedShell(command, options = {}) {
  const privileged = buildPrivilegedShellCommand(command)
  return runProcess(privileged.binary, privileged.args, {
    ...options,
    shell: false,
  })
}

async function commandPath(command) {
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
      timeoutMs: 4_000,
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
        timeoutMs: 4_000,
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
          timeoutMs: 4_000,
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
        timeoutMs: 4_000,
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
      timeoutMs: 4_000,
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
      timeoutMs: 3_000,
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
        timeoutMs: 4_000,
        ...runOptions,
      })
    },
    ...options,
  })
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
  const bundledNodePath = getPreferredNodeBinary()
  const bundledNpmPath = getPreferredNpmBinary(bundledNodePath)
  const nodePath = (await commandPath('node')) || (existsSync(bundledNodePath) ? bundledNodePath : null)
  const npmPath =
    (await commandPath(process.platform === 'win32' ? 'npm.cmd' : 'npm')) ||
    ((!bundledNpmPath.includes(path.sep) || existsSync(bundledNpmPath)) ? bundledNpmPath : null)
  const openclawPath = await commandPath(process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw')
  const resolvedContainerRuntime =
    containerRuntime ||
    (await detectContainerRuntime({
      commandExists: commandResponds,
    }))
  const gitVersion = gitPath ? await detectCommandVersion('git', ['--version']) : null
  const nodeVersion = nodePath ? await detectCommandVersion('node', ['--version']) : null
  const npmVersion = npmPath
    ? await detectCommandVersion(process.platform === 'win32' ? 'npm.cmd' : 'npm', ['--version'])
    : null
  const ollamaAvailable = await commandExists('ollama')
  const ollamaVersion = ollamaAvailable ? await detectCommandVersion('ollama', ['--version']) : null
  const openclawAvailable =
    Boolean(openclawPath) || (await commandExists('openclaw'))
  const openclawVersion = openclawAvailable
    ? await detectCommandVersion(process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw', ['--version'])
    : null
  const latestOpenclawVersion = includeUpdateChecks && openclawAvailable
    ? await detectLatestNpmPackageVersion('openclaw', npmPath)
    : null
  const dockerVersion = resolvedContainerRuntime.dockerCliPath
    ? await detectCommandVersion('docker', ['--version'])
    : null
  const dockerComposeVersion = resolvedContainerRuntime.composeAvailable
    ? await detectCommandVersion('docker', ['compose', 'version'])
    : null
  const minimumNodeVersion = '22.0.0'
  const nodeNeedsUpdate =
    Boolean(nodeVersion) && compareVersions(nodeVersion, minimumNodeVersion) < 0
  const packageTargets = getDependencyPackageTargets(packageManager.id)
  const bundledNodeResolvedPath = bundledNodePath.includes(path.sep) ? path.resolve(bundledNodePath) : null
  const bundledNpmResolvedPath =
    bundledNpmPath.includes(path.sep) && existsSync(bundledNpmPath) ? path.resolve(bundledNpmPath) : null
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
  const storagePath = normalizeInputPath(
    overrides.storagePath ||
      persistedConfig.storagePath ||
      path.join(installPath, 'storage')
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

function getPreferredNodeBinary() {
  const candidates = [
    process.execPath,
    '/opt/homebrew/opt/node@22/bin/node',
    '/usr/local/opt/node@22/bin/node',
    'node',
  ]

  return candidates.find((candidate) => candidate === 'node' || existsSync(candidate)) || 'node'
}

function getPreferredNpmBinary(nodeBinary) {
  const candidatePaths = [
    path.join(path.dirname(nodeBinary), process.platform === 'win32' ? 'npm.cmd' : 'npm'),
    '/opt/homebrew/opt/node@22/bin/npm',
    '/usr/local/opt/node@22/bin/npm',
    process.platform === 'win32' ? 'npm.cmd' : 'npm',
  ]

  return candidatePaths.find((candidate) => !candidate.includes(path.sep) || existsSync(candidate)) ||
    (process.platform === 'win32' ? 'npm.cmd' : 'npm')
}

function getShellEnv() {
  const preferredNodeBinary = getPreferredNodeBinary()
  const preferredNodeBin = preferredNodeBinary.includes(path.sep)
    ? path.dirname(preferredNodeBinary)
    : null

  return {
    ...process.env,
    PATH: [
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
    normalizedPath === 'admin/build/node_modules' ||
    normalizedPath.startsWith('admin/build/node_modules/') ||
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
  const nodeBinary = getPreferredNodeBinary()
  const launcherPath = path.join(config.installPath, 'scripts', 'run-roachnet.mjs')

  if (!existsSync(launcherPath)) {
    throw new Error(`Missing RoachNet launcher at ${launcherPath}.`)
  }

  appendTaskLog(task, 'Smoke testing the contained runtime before finalizing the install...')

  try {
    await runProcess(nodeBinary, [launcherPath], {
      cwd: config.installPath,
      env: {
        ...getShellEnv(),
        ROACHNET_NO_BROWSER: '1',
      },
      timeoutMs: PORT_WAIT_TIMEOUT_MS + 120_000,
    })
    appendTaskLog(task, `Contained runtime answered ${new URL('/api/health', envValues.URL).toString()}.`)
  } finally {
    await runProcess(nodeBinary, [launcherPath, '--stop'], {
      cwd: config.installPath,
      env: {
        ...getShellEnv(),
        ROACHNET_NO_BROWSER: '1',
      },
      timeoutMs: 30_000,
    }).catch(() => {})
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
      OLLAMA_BASE_URL: "${resolvedOllamaBaseUrl}"
      OPENCLAW_BASE_URL: "${resolvedOpenClawBaseUrl}"
      ROACHNET_DB_ROOT_PASSWORD: "${resolvedDbRootPassword}"
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
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
    volumes:
      - "${runtimeRoot}/redis:/data"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 15s
      timeout: 10s
      retries: 20
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
  const dbPassword = existingValues.DB_PASSWORD || randomSecret(16)
  const dbRootPassword = existingValues.ROACHNET_DB_ROOT_PASSWORD || randomSecret(16)
  const appKey = existingValues.APP_KEY || randomSecret(24)
  const host = existingValues.HOST || '127.0.0.1'
  const storagePath = normalizeInputPath(config.storagePath || existingValues.NOMAD_STORAGE_PATH || path.join(repoPath, 'storage'))
  const openClawWorkspacePath = normalizeInputPath(path.join(storagePath, 'openclaw'))
  const sqliteDbPath = normalizeInputPath(path.join(storagePath, 'state', 'roachnet.sqlite'))
  const localToolsPath = normalizeInputPath(path.join(repoPath, 'bin'))
  const ollamaBaseUrl = existingValues.OLLAMA_BASE_URL || 'http://127.0.0.1:11434'
  const openClawBaseUrl = existingValues.OPENCLAW_BASE_URL || 'http://127.0.0.1:13001'

  await ensureDirectory(storagePath)
  await ensureDirectory(openClawWorkspacePath)
  await ensureDirectory(path.dirname(sqliteDbPath))

  const envValues = {
    ...exampleValues,
    ...existingValues,
    PORT: port,
    HOST: host,
    URL: existingValues.URL || `http://${host}:${port}`,
    LOG_LEVEL: existingValues.LOG_LEVEL || 'info',
    APP_KEY: appKey,
    NODE_ENV: existingValues.NODE_ENV || 'production',
    DB_CONNECTION: existingValues.DB_CONNECTION || 'sqlite',
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
    OPENCLAW_BASE_URL: openClawBaseUrl,
    OPENCLAW_WORKSPACE_PATH: openClawWorkspacePath,
    ROACHNET_LOCAL_BIN_PATH: localToolsPath,
    ROACHNET_CONTAINERLESS_MODE: existingValues.ROACHNET_CONTAINERLESS_MODE || '1',
    ROACHNET_DISABLE_QUEUE: existingValues.ROACHNET_DISABLE_QUEUE || '1',
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
  appendTaskLog(task, 'The first boot will use the contained local runtime lane instead of installing global dependencies.')

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

async function launchInstalledRoachNet(repoPath, openPath) {
  const nodeBinary = getPreferredNodeBinary()
  spawn(nodeBinary, [path.join(repoPath, 'scripts', 'run-roachnet.mjs')], {
    cwd: repoPath,
    detached: true,
    stdio: 'ignore',
    env: {
      ...getShellEnv(),
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

    setPhase('Staging RoachNet')
    await ensureRepository(stagedConfig, stagedConfig.installPath, task)

    setPhase('Preparing contained runtime')
    const prepared = await prepareEnvironmentFiles(stagedConfig, stagedConfig.installPath, task)

    setPhase('Installing native desktop app')
    await installNativeDesktopApp(stagedConfig, task)

    setPhase('Verifying contained runtime')
    await smokeTestInstalledRuntime(stagedConfig, prepared.envValues, task)

    setPhase('Finalizing install')
    await finalizeInstallRoot(stagedConfig.installPath, normalizedConfig.installPath, task)
    const finalized = await prepareEnvironmentFiles(normalizedConfig, normalizedConfig.installPath, task)

    if (normalizedConfig.autoLaunch) {
      setPhase('Launching RoachNet')
      await launchNativeDesktopApp(normalizedConfig.installedAppPath)
      appendTaskLog(task, `RoachNet desktop app launched from ${normalizedConfig.installedAppPath}`)
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
    task.error = error.message
    appendTaskLog(task, `Setup failed: ${error.message}`)
    await rm(stagingInstallPath, { recursive: true, force: true })
    appendTaskLog(task, 'Removed the staged install so this Mac can retry setup cleanly.')
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

  if (!cachedDiagnostics || runtimeState.diagnosticsCache.expiresAt <= now) {
    const packageManager = await detectPackageManager()
    const containerRuntime = await detectContainerRuntime()
    cachedDiagnostics = {
      packageManager,
      containerRuntime,
      dependencies: await detectDependencies({ containerRuntime, includeUpdateChecks: false }),
    }
    runtimeState.diagnosticsCache = {
      value: cachedDiagnostics,
      expiresAt: now + INSTALLER_DIAGNOSTICS_CACHE_TTL_MS,
    }
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
      detectionPending: false,
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
    await launchInstalledRoachNet(installPath, '/easy-setup')
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
