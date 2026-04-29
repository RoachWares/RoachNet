#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { cp, mkdtemp, readdir } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { writeSha256Sidecar } from './build-native-macos-packaging-support.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const packagePath = path.join(repoRoot, 'native', 'macos')
const distPath = path.join(packagePath, 'dist')
const iconSource = path.join(repoRoot, 'branding', 'RoachNet_Icon-ResizedREAL.png')
const launchGuideVideoPath = path.join(
  repoRoot,
  'native',
  'macos',
  'Sources',
  'RoachNetApp',
  'Resources',
  'roachnet-launch-guide.mp4'
)
const installerHelperPath = path.join(
  repoRoot,
  'native',
  'macos',
  'installer-support',
  'RoachNet Fix.command'
)
const appVersion = JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8')).version || '1.0.0'
const bundledNodeVersion = 'v22.22.2'
const bundledOpenClawPackage = process.env.ROACHNET_BUNDLED_OPENCLAW_PACKAGE?.trim() || 'openclaw@2026.4.9'
const codesignIdentity = process.env.ROACHNET_CODESIGN_IDENTITY?.trim() || ''
const notaryProfile = process.env.ROACHNET_NOTARY_PROFILE?.trim() || ''
const notaryKeychain = process.env.ROACHNET_NOTARY_KEYCHAIN?.trim() || ''
const skipDmg = process.env.ROACHNET_SKIP_DMG === '1'
const OLLAMA_RELEASE_API_URL = 'https://api.github.com/repos/ollama/ollama/releases/latest'
const OLLAMA_DIRECT_DOWNLOAD_URL =
  process.env.ROACHNET_BUNDLED_OLLAMA_URL?.trim() || 'https://ollama.com/download/ollama-darwin.tgz'
const OLLAMA_FALLBACK_VERSION =
  process.env.ROACHNET_BUNDLED_OLLAMA_VERSION?.trim() || 'contained'

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd || repoRoot,
      env: options.env || process.env,
      stdio: options.stdio || 'inherit',
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

    if (options.stdio === 'pipe') {
      child.stdout?.on('data', (chunk) => {
        stdout += chunk.toString()
      })
      child.stderr?.on('data', (chunk) => {
        stderr += chunk.toString()
      })
    }

    child.on('error', reject)
    child.on('close', (code) => {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }

      if (timedOut) {
        reject(new Error(`${command} ${args.join(' ')} timed out after ${options.timeoutMs}ms\n${stderr}`))
        return
      }

      if (code === 0) {
        resolve({ stdout, stderr })
      } else {
        reject(new Error(`${command} ${args.join(' ')} failed with exit code ${code}\n${stderr}`))
      }
    })
  })
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

function readBundleInfoPlist(bundlePath) {
  const infoPlistPath = path.join(bundlePath, 'Contents', 'Info.plist')
  if (!existsSync(infoPlistPath)) {
    throw new Error(`Missing Info.plist at ${infoPlistPath}`)
  }

  return readFileSync(infoPlistPath, 'utf8')
}

function readPlistStringValue(plistContent, key) {
  const match = plistContent.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`))
  return match?.[1]?.trim() || null
}

function readBundleVersion(bundlePath) {
  return readPlistStringValue(readBundleInfoPlist(bundlePath), 'CFBundleShortVersionString')
}

function serializeEnvFile(values) {
  return (
    Object.entries(values)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, value]) => `${key}=${String(value)}`)
      .join('\n') + '\n'
  )
}

function getPreferredNodeBinary() {
  const currentNodeBinary = process.execPath
  if (currentNodeBinary && existsSync(currentNodeBinary)) {
    return currentNodeBinary
  }

  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/node'
  return existsSync(macHomebrewNode22) ? macHomebrewNode22 : process.execPath
}

function getPreferredNpmBinary() {
  const nodeBinary = getPreferredNodeBinary()
  const localNodeNpm = nodeBinary.includes(path.sep)
    ? path.join(path.dirname(nodeBinary), process.platform === 'win32' ? 'npm.cmd' : 'npm')
    : null
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/npm'

  return [localNodeNpm, macHomebrewNode22, 'npm']
    .filter(Boolean)
    .find((candidate) => candidate === 'npm' || existsSync(candidate)) || 'npm'
}

function sanitizeCacheKey(value) {
  return value.replace(/[^a-zA-Z0-9._-]+/g, '-')
}

async function fetchJson(url) {
  const token = process.env.GITHUB_TOKEN?.trim() || process.env.GH_TOKEN?.trim() || ''
  const headers = {
    'user-agent': 'RoachNet-Bundler',
    accept: 'application/json',
  }
  if (token && url.startsWith('https://api.github.com/')) {
    headers.authorization = `Bearer ${token}`
  }

  const response = await fetch(url, { headers })

  if (!response.ok) {
    throw new Error(`Request failed for ${url}: ${response.status} ${response.statusText}`)
  }

  return response.json()
}

async function downloadFile(url, destinationPath) {
  const response = await fetch(url, {
    headers: {
      'user-agent': 'RoachNet-Bundler',
      accept: '*/*',
    },
  })

  if (!response.ok || !response.body) {
    throw new Error(`Download failed for ${url}: ${response.status} ${response.statusText}`)
  }

  mkdirSync(path.dirname(destinationPath), { recursive: true })
  const arrayBuffer = await response.arrayBuffer()
  writeFileSync(destinationPath, Buffer.from(arrayBuffer))
}

async function getLatestOllamaRelease() {
  try {
    const release = await fetchJson(OLLAMA_RELEASE_API_URL)
    const asset = Array.isArray(release.assets)
      ? release.assets.find((entry) => entry?.name === 'ollama-darwin.tgz')
      : null

    return {
      version: release.tag_name?.replace(/^v/i, '') || OLLAMA_FALLBACK_VERSION,
      assetName: asset?.name || path.basename(new URL(OLLAMA_DIRECT_DOWNLOAD_URL).pathname) || 'ollama-darwin.tgz',
      url: asset?.browser_download_url || OLLAMA_DIRECT_DOWNLOAD_URL,
    }
  } catch (error) {
    console.warn(
      `Falling back to the direct Ollama bundle because the release lookup failed: ${error instanceof Error ? error.message : String(error)}`
    )

    return {
      version: OLLAMA_FALLBACK_VERSION,
      assetName: path.basename(new URL(OLLAMA_DIRECT_DOWNLOAD_URL).pathname) || 'ollama-darwin.tgz',
      url: OLLAMA_DIRECT_DOWNLOAD_URL,
    }
  }
}

async function ensureBundledOpenClawCache() {
  const cacheRoot = path.join(repoRoot, 'native', 'macos', '.cache', 'bundled-openclaw')
  const cacheKey = sanitizeCacheKey(bundledOpenClawPackage)
  const packageRoot = path.join(cacheRoot, cacheKey)
  const packageJsonPath = path.join(packageRoot, 'package.json')
  const installedBinaryPath = path.join(
    packageRoot,
    'node_modules',
    '.bin',
    process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw'
  )

  if (!existsSync(installedBinaryPath)) {
    console.log(`Preparing bundled OpenClaw payload from ${bundledOpenClawPackage}...`)
    rmSync(packageRoot, { recursive: true, force: true })
    mkdirSync(packageRoot, { recursive: true })
    writeFileSync(
      packageJsonPath,
      JSON.stringify(
        {
          name: 'roachnet-bundled-openclaw',
          private: true,
        },
        null,
        2
      ) + '\n',
      'utf8'
    )

    await run(getPreferredNpmBinary(), ['install', '--prefix', packageRoot, '--no-audit', '--no-fund', '--omit=dev', bundledOpenClawPackage], {
      stdio: 'pipe',
      env: {
        ...process.env,
        npm_config_update_notifier: 'false',
        npm_config_fund: 'false',
        npm_config_audit: 'false',
      },
    })
  } else {
    console.log(`Using cached bundled OpenClaw payload from ${packageRoot}...`)
  }

  return packageRoot
}

async function prepareBundledOpenClawPackage(stagedSourceRoot) {
  const packageRoot = await ensureBundledOpenClawCache()
  const destinationRoot = path.join(stagedSourceRoot, 'runtime', 'vendor', 'openclaw')
  await copyTreeFast(packageRoot, destinationRoot)
}

async function ensureBundledOllamaCache() {
  if (!(process.platform === 'darwin' && process.arch === 'arm64')) {
    return null
  }

  const release = await getLatestOllamaRelease()
  const cacheRoot = path.join(repoRoot, 'native', 'macos', '.cache', 'bundled-ollama')
  const archivePath = path.join(cacheRoot, release.assetName)
  const extractedRoot = path.join(cacheRoot, sanitizeCacheKey(release.version))
  const extractedBinaryPath = path.join(extractedRoot, 'ollama')

  if (!existsSync(extractedBinaryPath)) {
    console.log(`Preparing bundled Ollama payload ${release.version}...`)
    rmSync(extractedRoot, { recursive: true, force: true })
    mkdirSync(cacheRoot, { recursive: true })
    await downloadFile(release.url, archivePath)
    mkdirSync(extractedRoot, { recursive: true })
    await run('tar', ['-xzf', archivePath, '-C', extractedRoot], {
      stdio: 'pipe',
    })
  } else {
    console.log(`Using cached bundled Ollama payload from ${extractedRoot}...`)
  }

  return extractedRoot
}

async function prepareBundledOllamaPayload(stagedSourceRoot) {
  const extractedRoot = await ensureBundledOllamaCache()
  if (!extractedRoot) {
    return
  }

  const destinationRoot = path.join(stagedSourceRoot, 'runtime', 'vendor', 'ollama')
  await copyTreeFast(extractedRoot, destinationRoot)
}

async function prepareInstallerContainedTooling(installerAssetsPath) {
  const openClawDestination = path.join(installerAssetsPath, 'bundled-openclaw')
  const ollamaDestination = path.join(installerAssetsPath, 'bundled-ollama')
  const packageRoot = await ensureBundledOpenClawCache()
  await copyTreeFast(packageRoot, openClawDestination)

  const extractedRoot = await ensureBundledOllamaCache()
  if (extractedRoot) {
    await copyTreeFast(extractedRoot, ollamaDestination)
  }
}

function getBundledNodePlatformTag() {
  if (process.arch === 'arm64') {
    return 'darwin-arm64'
  }

  if (process.arch === 'x64') {
    return 'darwin-x64'
  }

  throw new Error(`RoachNet does not have a bundled Node runtime definition for macOS ${process.arch}.`)
}

function resolveNodeRuntimeRoot(nodeBinaryPath) {
  if (!nodeBinaryPath || !existsSync(nodeBinaryPath)) {
    return null
  }

  try {
    return path.dirname(path.dirname(realpathSync(nodeBinaryPath)))
  } catch {
    return path.dirname(path.dirname(nodeBinaryPath))
  }
}

function isAllowedBundledLibraryPath(libraryPath, runtimeRoot) {
  if (!libraryPath) {
    return false
  }

  if (
    libraryPath.startsWith('@rpath/') ||
    libraryPath.startsWith('@loader_path/') ||
    libraryPath.startsWith('@executable_path/')
  ) {
    return true
  }

  if (libraryPath.startsWith('/System/Library/') || libraryPath.startsWith('/usr/lib/')) {
    return true
  }

  const resolvedRuntimeRoot = path.resolve(runtimeRoot)
  return libraryPath === resolvedRuntimeRoot || libraryPath.startsWith(`${resolvedRuntimeRoot}${path.sep}`)
}

async function inspectDynamicLibraries(binaryPath) {
  if (process.platform !== 'darwin') {
    return []
  }

  const { stdout } = await run('otool', ['-L', binaryPath], {
    stdio: 'pipe',
    timeoutMs: 4_000,
  })

  return stdout
    .split(/\r?\n/)
    .slice(1)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => line.split(' (compatibility version')[0]?.trim())
    .filter(Boolean)
}

async function verifyNodeRuntimeRoot(runtimeRoot, options = {}) {
  if (!runtimeRoot) {
    return false
  }

  const binaryPath = path.join(runtimeRoot, 'bin', 'node')
  if (!existsSync(binaryPath)) {
    return false
  }

  const attempts = options.attempts ?? 2
  const timeoutMs = options.timeoutMs ?? 10_000

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const versionCheckDir = await mkdtemp(path.join(os.tmpdir(), 'roachnet-node-version-'))
      const versionPath = path.join(versionCheckDir, 'version.txt')
      try {
        await run(
          binaryPath,
          [
            '-e',
            "require('node:fs').writeFileSync(process.argv[1], process.versions.node)",
            versionPath,
          ],
          {
            stdio: 'ignore',
            timeoutMs,
          }
        )
        const resolvedVersion = `v${readFileSync(versionPath, 'utf8').trim()}`
        const expectedMajor = bundledNodeVersion.replace(/^v/, '').split('.')[0]
        const actualMajor = resolvedVersion.replace(/^v/, '').split('.')[0]
        if (actualMajor !== expectedMajor) {
          return false
        }
      } finally {
        rmSync(versionCheckDir, { recursive: true, force: true })
      }

      if (options.requirePortable !== true || process.platform !== 'darwin') {
        return true
      }

      const libraries = await inspectDynamicLibraries(binaryPath)
      return libraries.every((libraryPath) => isAllowedBundledLibraryPath(libraryPath, runtimeRoot))
    } catch {
      if (attempt + 1 >= attempts) {
        return false
      }

      await new Promise((resolve) => setTimeout(resolve, 750))
    }
  }

  return false
}

async function verifyBundleMetadata(bundlePath, expectedVersion, label) {
  if (!existsSync(bundlePath)) {
    throw new Error(`Missing ${label} bundle at ${bundlePath}`)
  }

  const actualVersion = readBundleVersion(bundlePath)
  if (actualVersion !== expectedVersion) {
    throw new Error(
      `${label} bundle version mismatch. Expected ${expectedVersion}, found ${actualVersion || 'missing'} at ${bundlePath}`
    )
  }
}

async function verifyEmbeddedNodeBundle(bundlePath, label) {
  const runtimeRoot = path.join(bundlePath, 'Contents', 'Resources', 'EmbeddedRuntime', 'node')
  const binaryPath = path.join(runtimeRoot, 'bin', 'node')

  if (!existsSync(binaryPath)) {
    throw new Error(`${label} is missing the embedded Node runtime binary at ${binaryPath}`)
  }

  const libraries = await inspectDynamicLibraries(binaryPath)
  const invalidLibraries = libraries.filter(
    (libraryPath) => !isAllowedBundledLibraryPath(libraryPath, runtimeRoot)
  )

  if (invalidLibraries.length > 0) {
    throw new Error(
      `${label} is carrying a non-portable embedded Node runtime at ${runtimeRoot}\n${invalidLibraries.join('\n')}`
    )
  }
}

async function verifyBuiltArtifacts() {
  const desktopBundlePath = path.join(distPath, 'RoachNet.app')
  const setupBundlePath = path.join(distPath, 'RoachNet Setup.app')
  const installerAssetArchivePath = path.join(
    setupBundlePath,
    'Contents',
    'Resources',
    'InstallerAssets',
    `RoachNet-${appVersion}-mac-${process.arch}.zip`
  )

  await verifyBundleMetadata(desktopBundlePath, appVersion, 'RoachNet')
  await verifyBundleMetadata(setupBundlePath, appVersion, 'RoachNet Setup')

  await verifyEmbeddedNodeBundle(desktopBundlePath, 'RoachNet')
  await verifyEmbeddedNodeBundle(setupBundlePath, 'RoachNet Setup')

  const bundledSourceArchivePaths = [
    ['RoachNet', path.join(desktopBundlePath, 'Contents', 'Resources', 'RoachNetSource.tar.gz')],
    ['RoachNet Setup', path.join(setupBundlePath, 'Contents', 'Resources', 'RoachNetSource.tar.gz')],
  ]

  for (const [label, archivePath] of bundledSourceArchivePaths) {
    if (!existsSync(archivePath)) {
      throw new Error(`Missing bundled source archive for ${label} at ${archivePath}`)
    }

    await verifyBundledSourceArchive(archivePath, label)
  }

  if (!existsSync(installerAssetArchivePath)) {
    throw new Error(`Missing installer asset archive at ${installerAssetArchivePath}`)
  }
}

async function verifyBundledSourceArchive(archivePath, label) {
  const { stdout } = await run('tar', ['-tzf', archivePath], {
    stdio: 'pipe',
  })

  const entries = stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)

  const suspiciousEntries = entries.filter(
    (entry) =>
      bundledSourceForbiddenArchivePrefixes.some((prefix) => entry.startsWith(prefix)) ||
      bundledSourceForbiddenArchivePatterns.some((pattern) => pattern.test(entry))
  )

  if (suspiciousEntries.length > 0) {
    throw new Error(
      `${label} bundled source archive is carrying local runtime or indexed-content artifacts:\n${suspiciousEntries
        .slice(0, 20)
        .join('\n')}`
    )
  }
}

async function ensureBundledNodeRuntime() {
  const cacheRoot = path.join(packagePath, '.cache', 'node-runtime')
  const platformTag = getBundledNodePlatformTag()
  const archiveName = `node-${bundledNodeVersion}-${platformTag}.tar.gz`
  const extractedFolderName = `node-${bundledNodeVersion}-${platformTag}`
  const archivePath = path.join(cacheRoot, archiveName)
  const extractedPath = path.join(cacheRoot, extractedFolderName)
  const bundledNodeBinary = path.join(extractedPath, 'bin', 'node')
  const candidateRoots = [
    process.env.ROACHNET_BUNDLED_NODE_ROOT?.trim(),
    existsSync(bundledNodeBinary) ? extractedPath : null,
  ].filter(Boolean)

  for (const candidateRoot of candidateRoots) {
    if (await verifyNodeRuntimeRoot(candidateRoot, { requirePortable: true })) {
      return candidateRoot
    }
  }

  mkdirSync(cacheRoot, { recursive: true })

  if (!existsSync(archivePath)) {
    const downloadURL = `https://nodejs.org/dist/${bundledNodeVersion}/${archiveName}`
    console.log(`Downloading bundled Node runtime from ${downloadURL}...`)
    await run('curl', ['-fsSLo', archivePath, downloadURL], { stdio: 'pipe' })
  }

  discardPath(extractedPath)
  await run('tar', ['-xzf', archivePath, '-C', cacheRoot], { stdio: 'pipe' })

  if (!(await verifyNodeRuntimeRoot(extractedPath, { requirePortable: true }))) {
    throw new Error(`Bundled Node runtime at ${bundledNodeBinary} could not execute after extraction.`)
  }

  return extractedPath
}

function getCodesignArgs(targetPath, options = {}) {
  const args = ['--force', '--sign', codesignIdentity || '-']

  if (codesignIdentity) {
    args.push('--options', 'runtime', '--timestamp')

    if (options.bundle === true) {
      args.push('--preserve-metadata=identifier,entitlements,flags,runtime')
    }
  }

  args.push(targetPath)
  return args
}

async function signCodeObject(targetPath, options = {}) {
  await run('codesign', getCodesignArgs(targetPath, options), { stdio: 'pipe' })
}

async function collectCodeSignTargets(rootPath) {
  if (!existsSync(rootPath)) {
    return []
  }

  const targets = []
  const queue = [rootPath]

  while (queue.length > 0) {
    const currentPath = queue.pop()
    const entries = await readdir(currentPath, { withFileTypes: true })

    for (const entry of entries) {
      if (entry.name === 'InstallerAssets') {
        continue
      }

      const entryPath = path.join(currentPath, entry.name)
      if (entry.isDirectory()) {
        queue.push(entryPath)
        continue
      }

      if (!entry.isFile()) {
        continue
      }

      const extension = path.extname(entry.name)
      if (
        extension === '.dylib' ||
        extension === '.node' ||
        entry.name === 'node'
      ) {
        targets.push(entryPath)
      }
    }
  }

  return targets.sort((left, right) => right.length - left.length)
}

async function signAppBundle(bundlePath) {
  const signTargetRoots = [
    path.join(bundlePath, 'Contents', 'MacOS'),
    path.join(bundlePath, 'Contents', 'Frameworks'),
    path.join(bundlePath, 'Contents', 'Resources', 'EmbeddedRuntime'),
  ]

  for (const rootPath of signTargetRoots) {
    const targets = await collectCodeSignTargets(rootPath)
    for (const targetPath of targets) {
      await signCodeObject(targetPath)
    }
  }

  await signCodeObject(bundlePath, { bundle: true })
}

async function clearLaunchMetadata(targetPath, options = {}) {
  if (process.platform !== 'darwin' || !existsSync(targetPath)) {
    return
  }

  if (options.recursive === true) {
    await run('xattr', ['-dr', 'com.apple.provenance', targetPath], {
      stdio: 'pipe',
    }).catch(() => {})

    await run('xattr', ['-dr', 'com.apple.quarantine', targetPath], {
      stdio: 'pipe',
    }).catch(() => {})

    await run('xattr', ['-cr', targetPath], {
      stdio: 'pipe',
    }).catch(() => {})
    return
  }

  await run('xattr', ['-d', 'com.apple.provenance', targetPath], {
    stdio: 'pipe',
  }).catch(() => {})

  await run('xattr', ['-d', 'com.apple.quarantine', targetPath], {
    stdio: 'pipe',
  }).catch(() => {})
}

async function clearEmbeddedRuntimeLaunchMetadata(bundlePath) {
  await clearLaunchMetadata(bundlePath, {
    recursive: true,
  })
  await clearLaunchMetadata(path.join(bundlePath, 'Contents', 'Resources', 'EmbeddedRuntime'), {
    recursive: true,
  })
}

async function ensureLaunchGuideVideo() {
  if (existsSync(launchGuideVideoPath) && process.env.ROACHNET_REBUILD_LAUNCH_GUIDE !== '1') {
    return
  }

  const nodeBinary = getPreferredNodeBinary()
  await run(nodeBinary, [path.join(repoRoot, 'scripts', 'build-launch-guide-video.mjs')], {
    cwd: repoRoot,
    env: {
      ...process.env,
      PATH: `${path.dirname(nodeBinary)}:${process.env.PATH || ''}`,
    },
  })
}

async function buildAdminRuntime() {
  const nodeBinary = getPreferredNodeBinary()
  if (process.env.ROACHNET_SKIP_ADMIN_RUNTIME_BUILD === '1') {
    console.log('Using the existing compiled admin runtime.')
    return
  }

  await run(nodeBinary, [path.join(repoRoot, 'scripts', 'build-admin-runtime.mjs')], {
    cwd: repoRoot,
    env: {
      ...process.env,
      PATH: `${path.dirname(nodeBinary)}:${process.env.PATH || ''}`,
    },
  })
}

async function buildSwiftPackage() {
  const env = {
    ...process.env,
    DEVELOPER_DIR:
      process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer',
  }

  await run('xcrun', ['swift', 'build', '--configuration', 'release', '--package-path', packagePath], {
    env,
  })

  const result = await run(
    'xcrun',
    ['swift', 'build', '--configuration', 'release', '--package-path', packagePath, '--show-bin-path'],
    { env, stdio: 'pipe' }
  )

  return result.stdout.trim()
}

async function buildIcns() {
  if (!existsSync(iconSource)) {
    return null
  }

  const tmpRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-iconset-'))
  const iconsetPath = path.join(tmpRoot, 'RoachNet.iconset')
  mkdirSync(iconsetPath, { recursive: true })

  const sizes = [
    [16, 'icon_16x16.png'],
    [32, 'icon_16x16@2x.png'],
    [32, 'icon_32x32.png'],
    [64, 'icon_32x32@2x.png'],
    [128, 'icon_128x128.png'],
    [256, 'icon_128x128@2x.png'],
    [256, 'icon_256x256.png'],
    [512, 'icon_256x256@2x.png'],
    [512, 'icon_512x512.png'],
    [1024, 'icon_512x512@2x.png'],
  ]

  for (const [size, name] of sizes) {
    await run('sips', ['-z', String(size), String(size), iconSource, '--out', path.join(iconsetPath, name)], {
      stdio: 'pipe',
    })
  }

  const icnsPath = path.join(tmpRoot, 'RoachNet.icns')
  await run('iconutil', ['-c', 'icns', iconsetPath, '-o', icnsPath], { stdio: 'pipe' })
  return icnsPath
}

const bundledSourceExcludes = [
  '.git/',
  '.netlify/',
  '.native/',
  '.next/',
  '.turbo/',
  'dist/',
  'release/',
  'desktop-dist/',
  'setup-dist/',
  'node_modules/',
  'runtime/',
  'storage/',
  'native/macos/.build/',
  'native/macos/.cache/',
  'native/macos/.swiftpm/',
  'native/macos/dist/',
  'native/linux/target/',
  'native/windows/bin/',
  'native/windows/obj/',
  'admin/node_modules/',
  'admin/build/node_modules/',
  'admin/build/storage/',
  'admin/build/tmp/',
  'admin/build/uploads/',
  'admin/build/public/uploads/',
  'admin/build/*.sqlite',
  'admin/build/*.sqlite-*',
  'admin/build/*.db',
  'admin/build/*.db-*',
  'admin/build/*.jsonl',
  'admin/build/*.ndjson',
  'admin/build/vaults.json',
  'admin/build/roachnet-runtime-processes.json',
  'admin/.runtime-build-cache/',
  'admin/storage/',
  'installer/node_modules/',
  'admin/.env',
  '*.DS_Store',
  '*.dmg',
  '*.zip',
  '*.pkg',
  '*.zim',
  '*node_modules_node*',
  '*/storage/logs/',
  '*/storage/tmp/',
]

const bundledSourceForbiddenArchivePrefixes = [
  'RoachNetSource/storage/',
  'RoachNetSource/admin/storage/',
  'RoachNetSource/admin/build/storage/',
  'RoachNetSource/admin/build/tmp/',
  'RoachNetSource/admin/build/uploads/',
  'RoachNetSource/admin/build/public/uploads/',
]

const bundledSourceForbiddenArchivePatterns = [
  /\/vaults\.json$/i,
  /\.sqlite(?:$|[-.])/i,
  /\.db(?:$|[-.])/i,
  /\.jsonl$/i,
  /\.ndjson$/i,
  /\/roachnet-runtime-processes\.json$/i,
]

const bundledSourceDirectories = [
  'scripts',
  'setup-ui',
  'ops',
  'collections',
]

const bundledSourceFiles = [
  'package.json',
  'roachnet.upstream.json',
]

const bundledAdminFiles = [
  'package.json',
  'package-lock.json',
  '.env.example',
]

async function syncTree(sourcePath, destinationPath, excludePatterns = bundledSourceExcludes) {
  mkdirSync(destinationPath, { recursive: true })

  const args = [
    '-a',
    '--delete',
    ...excludePatterns.flatMap((pattern) => ['--exclude', pattern]),
    `${sourcePath}/`,
    `${destinationPath}/`,
  ]

  await run('rsync', args, { stdio: 'pipe' })
}

async function copyTreeFast(sourcePath, destinationPath) {
  discardPath(destinationPath)
  mkdirSync(path.dirname(destinationPath), { recursive: true })
  try {
    // On APFS this avoids a full byte-for-byte duplicate pass for large bundle trees.
    await run('ditto', ['--clone', sourcePath, destinationPath], {
      stdio: 'pipe',
      timeoutMs: 120_000,
    })
  } catch (error) {
    discardPath(destinationPath)
    console.warn(
      `[build-native-macos-apps] Falling back to a recursive copy for ${path.basename(destinationPath)}: ${
        error instanceof Error ? error.message : String(error)
      }`
    )
    await cp(sourcePath, destinationPath, { recursive: true, force: true })
  }
}

function discardPath(targetPath) {
  if (!existsSync(targetPath)) {
    return
  }

  const parentPath = path.dirname(targetPath)
  const trashedPath = path.join(parentPath, `${path.basename(targetPath)}.discard-${Date.now()}`)

  try {
    renameSync(targetPath, trashedPath)
  } catch {
    rmSync(targetPath, { recursive: true, force: true })
    return
  }

  const cleanup = spawn('rm', ['-rf', trashedPath], {
    cwd: repoRoot,
    detached: true,
    stdio: 'ignore',
  })
  cleanup.unref()
}

async function copyBundledSourceTree(destinationPath) {
  const bundledEnvSource = path.join(repoRoot, 'admin', '.env.example')
  const bundledEnvDestination = path.join(destinationPath, 'admin', '.env')

  discardPath(destinationPath)
  console.log(`Bundling source tree into ${destinationPath}...`)
  await stageBundledSourcePayload(destinationPath)

  const bundledBuildNodeModulesSource = path.join(repoRoot, 'admin', 'build', 'node_modules')
  const bundledBuildNodeModulesDestination = path.join(destinationPath, 'admin', 'build', 'node_modules')
  if (existsSync(bundledBuildNodeModulesSource)) {
    console.log(`Copying bundled runtime dependencies into ${bundledBuildNodeModulesDestination}...`)
    await copyTreeFast(bundledBuildNodeModulesSource, bundledBuildNodeModulesDestination)
    await materializeBundledRuntimeArtifacts(bundledBuildNodeModulesDestination)
  }

  if (existsSync(bundledEnvSource)) {
    console.log(`Copying bundled environment file into ${bundledEnvDestination}...`)
    const bundledEnvValues = parseEnvFile(readFileSync(bundledEnvSource, 'utf8'))
    delete bundledEnvValues.APP_KEY
    delete bundledEnvValues.DB_PASSWORD
    delete bundledEnvValues.ROACHNET_DB_ROOT_PASSWORD
    delete bundledEnvValues.GITHUB_TOKEN
    delete bundledEnvValues.NETLIFY_AUTH_TOKEN
    delete bundledEnvValues.OPENAI_API_KEY
    delete bundledEnvValues.ANTHROPIC_API_KEY
    delete bundledEnvValues.NOMAD_STORAGE_PATH
    delete bundledEnvValues.OPENCLAW_WORKSPACE_PATH
    writeFileSync(bundledEnvDestination, serializeEnvFile(bundledEnvValues), 'utf8')
  }
}

async function createBundledSourceArchive(archivePath) {
  const stagingRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-bundled-source-'))
  const stagedSourceRoot = path.join(stagingRoot, 'RoachNetSource')
  const bundledEnvSource = path.join(repoRoot, 'admin', '.env.example')
  const bundledEnvDestination = path.join(stagedSourceRoot, 'admin', '.env')
  const bundledBuildNodeModulesSource = path.join(repoRoot, 'admin', 'build', 'node_modules')
  const bundledBuildNodeModulesDestination = path.join(stagedSourceRoot, 'admin', 'build', 'node_modules')

  try {
    console.log(`Preparing bundled source archive at ${archivePath}...`)
    await stageBundledSourcePayload(stagedSourceRoot)

    if (existsSync(bundledBuildNodeModulesSource)) {
      console.log(`Copying bundled runtime dependencies into ${bundledBuildNodeModulesDestination}...`)
      await copyTreeFast(bundledBuildNodeModulesSource, bundledBuildNodeModulesDestination)
      await materializeBundledRuntimeArtifacts(bundledBuildNodeModulesDestination)
    }

    if (existsSync(bundledEnvSource)) {
      console.log(`Copying bundled environment file into ${bundledEnvDestination}...`)
      const bundledEnvValues = parseEnvFile(readFileSync(bundledEnvSource, 'utf8'))
      delete bundledEnvValues.APP_KEY
      delete bundledEnvValues.DB_PASSWORD
      delete bundledEnvValues.ROACHNET_DB_ROOT_PASSWORD
      delete bundledEnvValues.GITHUB_TOKEN
      delete bundledEnvValues.NETLIFY_AUTH_TOKEN
      delete bundledEnvValues.OPENAI_API_KEY
      delete bundledEnvValues.ANTHROPIC_API_KEY
      delete bundledEnvValues.NOMAD_STORAGE_PATH
      delete bundledEnvValues.OPENCLAW_WORKSPACE_PATH
      writeFileSync(bundledEnvDestination, serializeEnvFile(bundledEnvValues), 'utf8')
    }

    discardPath(archivePath)
    mkdirSync(path.dirname(archivePath), { recursive: true })
    await run('tar', ['-czf', archivePath, '-C', stagingRoot, 'RoachNetSource'], {
      stdio: 'pipe',
    })
  } finally {
    rmSync(stagingRoot, { recursive: true, force: true })
  }
}

async function stageBundledSourcePayload(destinationPath) {
  discardPath(destinationPath)
  mkdirSync(destinationPath, { recursive: true })

  for (const relativeFilePath of bundledSourceFiles) {
    const sourcePath = path.join(repoRoot, relativeFilePath)
    const targetPath = path.join(destinationPath, relativeFilePath)
    if (!existsSync(sourcePath)) {
      continue
    }

    mkdirSync(path.dirname(targetPath), { recursive: true })
    await cp(sourcePath, targetPath, { force: true })
  }

  for (const relativeDirectoryPath of bundledSourceDirectories) {
    const sourcePath = path.join(repoRoot, relativeDirectoryPath)
    const targetPath = path.join(destinationPath, relativeDirectoryPath)
    if (!existsSync(sourcePath)) {
      continue
    }

    await copyTreeFast(sourcePath, targetPath)
  }

  const adminRoot = path.join(destinationPath, 'admin')
  mkdirSync(adminRoot, { recursive: true })

  for (const relativeFilePath of bundledAdminFiles) {
    const sourcePath = path.join(repoRoot, 'admin', relativeFilePath)
    const targetPath = path.join(adminRoot, relativeFilePath)
    if (!existsSync(sourcePath)) {
      continue
    }

    mkdirSync(path.dirname(targetPath), { recursive: true })
    await cp(sourcePath, targetPath, { force: true })
  }

  const adminBuildSource = path.join(repoRoot, 'admin', 'build')
  const adminBuildDestination = path.join(adminRoot, 'build')
  if (existsSync(adminBuildSource)) {
    await syncTree(adminBuildSource, adminBuildDestination, [
      'node_modules/',
      'storage/',
      'tmp/',
      'uploads/',
      'public/uploads/',
      '*.sqlite',
      '*.sqlite-*',
      '*.db',
      '*.db-*',
      '*.jsonl',
      '*.ndjson',
      'vaults.json',
      'roachnet-runtime-processes.json',
    ])
  }
}

async function materializeBundledRuntimeArtifacts(nodeModulesRoot) {
  const libzimReleaseRoot = path.join(nodeModulesRoot, '@openzim', 'libzim', 'build', 'Release')
  const libzimTargetPath = path.join(libzimReleaseRoot, 'libzim.9.dylib')
  const libzimLinkPath = path.join(libzimReleaseRoot, 'libzim.dylib')

  if (!existsSync(libzimTargetPath)) {
    return
  }

  rmSync(libzimLinkPath, { force: true })
  await cp(libzimTargetPath, libzimLinkPath, { force: true })
}

async function copyBundledNodeRuntime(sourcePath, resourcesPath) {
  const destinationPath = path.join(resourcesPath, 'EmbeddedRuntime', 'node')
  console.log(`Bundling self-contained Node runtime into ${destinationPath}...`)
  await copyTreeFast(sourcePath, destinationPath)
  await clearLaunchMetadata(path.join(resourcesPath, 'EmbeddedRuntime'), { recursive: true })
}

async function detachMountedImage(imagePath) {
  let stdout = ''

  try {
    ;({ stdout } = await run('hdiutil', ['info'], { stdio: 'pipe' }))
  } catch {
    return
  }

  const normalizedPath = path.resolve(imagePath)
  const rootDisks = new Set()
  let sectionMatches = false

  for (const line of stdout.split(/\r?\n/)) {
    const trimmed = line.trim()

    if (trimmed.startsWith('image-path')) {
      const currentPath = trimmed.slice(trimmed.indexOf(':') + 1).trim()
      sectionMatches = path.resolve(currentPath) === normalizedPath
      continue
    }

    if (!sectionMatches) {
      continue
    }

    const diskMatch = trimmed.match(/^(\/dev\/disk\d+)/)
    if (diskMatch) {
      rootDisks.add(diskMatch[1])
    }
  }

  const disks = [...rootDisks].sort((left, right) => {
    const leftNumber = Number.parseInt(left.replace(/\D/g, ''), 10)
    const rightNumber = Number.parseInt(right.replace(/\D/g, ''), 10)
    return rightNumber - leftNumber
  })

  for (const disk of disks) {
    try {
      await run('hdiutil', ['detach', disk], { stdio: 'pipe' })
    } catch {
      try {
        await run('hdiutil', ['detach', '-force', disk], { stdio: 'pipe' })
      } catch {}
    }
  }
}

async function createSetupDmg(setupAppBundlePath) {
  const dmgPath = path.join(distPath, 'RoachNet-Setup-macOS.dmg')
  const stagingRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-dmg-staging-'))
  const stagingFolder = path.join(stagingRoot, 'RoachNet Setup')
  const stagedSetupAppPath = path.join(stagingFolder, path.basename(setupAppBundlePath))
  const stagedHelperPath = path.join(stagingFolder, 'RoachNet Fix.command')

  await detachMountedImage(dmgPath)
  rmSync(dmgPath, { force: true })

  mkdirSync(stagingFolder, { recursive: true })
  await cp(setupAppBundlePath, stagedSetupAppPath, { recursive: true, force: true })

  if (existsSync(installerHelperPath)) {
    await cp(installerHelperPath, stagedHelperPath, { force: true })
    chmodSync(stagedHelperPath, 0o755)
  }

  try {
    symlinkSync('/Applications', path.join(stagingFolder, 'Applications'))
  } catch {}

  try {
    await run(
      'hdiutil',
      [
        'create',
        '-volname',
        'RoachNet Setup',
        '-srcfolder',
        stagingFolder,
        '-ov',
        '-format',
        'UDZO',
        dmgPath,
      ],
      { stdio: 'pipe' }
    )
  } finally {
    rmSync(stagingRoot, { recursive: true, force: true })
  }

  return dmgPath
}

async function createMacAppArchive(sourceBundlePath, destinationArchivePath) {
  discardPath(destinationArchivePath)
  mkdirSync(path.dirname(destinationArchivePath), { recursive: true })
  await run(
    'ditto',
    ['-c', '-k', '--sequesterRsrc', '--keepParent', sourceBundlePath, destinationArchivePath],
    { stdio: 'pipe' }
  )
}

async function copySwiftPackageResources(executable, resourcesPath) {
  const executableDirectory = path.dirname(executable)
  const executableName = path.basename(executable)
  const entries = await readdir(executableDirectory, { withFileTypes: true })

  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.endsWith('.bundle')) {
      continue
    }

    if (!entry.name.endsWith(`_${executableName}.bundle`)) {
      continue
    }

    await cp(
      path.join(executableDirectory, entry.name),
      path.join(resourcesPath, entry.name),
      {
        recursive: true,
        force: true,
      }
    )
  }
}

async function bundleApp({ name, executable, identifier, iconPath, prepareResources, urlSchemes = [] }) {
  const bundlePath = path.join(distPath, `${name}.app`)
  const contentsPath = path.join(bundlePath, 'Contents')
  const macOSPath = path.join(contentsPath, 'MacOS')
  const resourcesPath = path.join(contentsPath, 'Resources')

  discardPath(bundlePath)
  mkdirSync(macOSPath, { recursive: true })
  mkdirSync(resourcesPath, { recursive: true })

  await cp(executable, path.join(macOSPath, path.basename(executable)))
  await copySwiftPackageResources(executable, resourcesPath)

  if (iconPath) {
    await cp(iconPath, path.join(resourcesPath, 'RoachNet.icns'))
  }

  if (prepareResources) {
    console.log(`Preparing bundled resources for ${name}...`)
    await prepareResources({ bundlePath, contentsPath, resourcesPath })
  }

  const urlSchemesPlist = urlSchemes.length
    ? `
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>CFBundleURLName</key>
      <string>${identifier}</string>
      <key>CFBundleURLSchemes</key>
      <array>
${urlSchemes.map((scheme) => `        <string>${scheme}</string>`).join('\n')}
      </array>
    </dict>
  </array>`
    : ''

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${path.basename(executable)}</string>
  <key>CFBundleIdentifier</key>
  <string>${identifier}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${appVersion}</string>
  <key>CFBundleVersion</key>
  <string>${appVersion}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>RoachNet uses the microphone for local voice prompts inside RoachClaw.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>RoachNet turns speech into local prompts so RoachClaw and Dev Studio can stay hands-free when you want them to.</string>
  ${iconPath ? '<key>CFBundleIconFile</key>\n  <string>RoachNet</string>' : ''}
  ${urlSchemesPlist}
</dict>
</plist>
`

  writeFileSync(path.join(contentsPath, 'Info.plist'), plist, 'utf8')
  console.log(`Signing ${name}...`)

  await signAppBundle(bundlePath)
  await clearEmbeddedRuntimeLaunchMetadata(bundlePath)

  return bundlePath
}

async function notarizeArtifact(artifactPath) {
  if (!codesignIdentity || !notaryProfile) {
    return
  }

  const submitArgs = ['notarytool', 'submit', artifactPath, '--keychain-profile', notaryProfile, '--wait']
  if (notaryKeychain) {
    submitArgs.push('--keychain', notaryKeychain)
  }

  await run('xcrun', submitArgs, { stdio: 'pipe' })

  await run('xcrun', ['stapler', 'staple', artifactPath], { stdio: 'pipe' })
}

async function main() {
  mkdirSync(distPath, { recursive: true })
  await ensureLaunchGuideVideo()
  await buildAdminRuntime()
  const binPath = await buildSwiftPackage()
  const iconPath = await buildIcns()
  const bundledNodeRuntimePath = await ensureBundledNodeRuntime()
  const desktopAppBundlePath = path.join(distPath, 'RoachNet.app')

  const apps = [
    {
      name: 'RoachNet',
      executable: path.join(binPath, 'RoachNetApp'),
      identifier: 'com.roachwares.roachnet',
      urlSchemes: ['roachnet'],
      prepareResources: async ({ resourcesPath }) => {
        await copyBundledNodeRuntime(bundledNodeRuntimePath, resourcesPath)
        const bundledSourceArchivePath = path.join(resourcesPath, 'RoachNetSource.tar.gz')
        await createBundledSourceArchive(bundledSourceArchivePath)
      },
    },
    {
      name: 'RoachNet Setup',
      executable: path.join(binPath, 'RoachNetSetup'),
      identifier: 'com.roachwares.roachnet.setup',
      prepareResources: async ({ resourcesPath }) => {
        await copyBundledNodeRuntime(bundledNodeRuntimePath, resourcesPath)
        const bundledSourceArchivePath = path.join(resourcesPath, 'RoachNetSource.tar.gz')
        const installerAssetsPath = path.join(resourcesPath, 'InstallerAssets')

        await createBundledSourceArchive(bundledSourceArchivePath)
        mkdirSync(installerAssetsPath, { recursive: true })
        writeFileSync(path.join(installerAssetsPath, 'setup-assets.marker'), '', 'utf8')
        await prepareInstallerContainedTooling(installerAssetsPath)

        if (existsSync(desktopAppBundlePath)) {
          await createMacAppArchive(
            desktopAppBundlePath,
            path.join(installerAssetsPath, `RoachNet-${appVersion}-mac-${process.arch}.zip`)
          )
        }
      },
    },
  ]

  for (const app of apps) {
    if (!existsSync(app.executable)) {
      throw new Error(`Missing native executable at ${app.executable}`)
    }
  }

  const builtBundles = []
  for (const app of apps) {
    builtBundles.push(await bundleApp({ ...app, iconPath }))
  }

  await verifyBuiltArtifacts()

  const setupAppBundlePath = builtBundles.find((bundlePath) => bundlePath.endsWith('RoachNet Setup.app'))
  if (setupAppBundlePath) {
    await notarizeArtifact(setupAppBundlePath)
    if (!skipDmg) {
      const dmgPath = await createSetupDmg(setupAppBundlePath)
      await notarizeArtifact(dmgPath)
      await writeSha256Sidecar(dmgPath)
      builtBundles.push(dmgPath)
    }
  }

  for (const bundle of builtBundles) {
    process.stdout.write(`${bundle}\n`)
  }
}

main().catch((error) => {
  console.error(error.message)
  process.exitCode = 1
})
