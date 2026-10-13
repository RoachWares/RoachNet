#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, createReadStream, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { cp, mkdtemp, readdir } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { writeSha256Sidecar } from './build-native-macos-packaging-support.mjs'
import { readDigestManifest, verifyImportedUpstreamFiles, verifyPackAgainstManifest } from './lib/roachspeech_pack_digests.mjs'
import { parseAcceptedNotarySubmission } from './lib/roachnet_notary_evidence.mjs'

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
const packageManifest = JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))
const appVersion = packageManifest.version || '1.0.0'
const appBuildNumber = String(packageManifest.buildNumber || '')

// ROA-40: stamp the source commit into each app's Info.plist (RoachNetSourceCommit)
// so About and `roachnet-runtime --build-info` say exactly what was built.
// "-dirty" marks a tree with uncommitted changes to tracked files.
export function resolveSourceCommit(environment = process.env, cwd = repoRoot) {
  const explicit = environment.ROACHNET_SOURCE_COMMIT?.trim()
  if (explicit) {
    if (!/^[0-9a-f]{40}(-dirty)?$/.test(explicit)) throw new Error('ROACHNET_SOURCE_COMMIT must be a full lowercase SHA, optionally with -dirty.')
    return explicit
  }
  const head = spawnSync('git', ['rev-parse', 'HEAD'], { cwd, encoding: 'utf8' })
  if (head.status !== 0 || !/^[0-9a-f]{40}$/.test(head.stdout.trim())) return ''
  const status = spawnSync('git', ['status', '--porcelain', '--untracked-files=no'], { cwd, encoding: 'utf8' })
  const dirty = status.status !== 0 || status.stdout.trim() !== ''
  return `${head.stdout.trim()}${dirty ? '-dirty' : ''}`
}
const sourceCommit = resolveSourceCommit()
export function resolveBuildModes(environment = process.env) {
  const releaseBuild = environment.ROACHNET_RELEASE_BUILD === '1'
  // A public-release request always wins if both flags are set: it must never
  // accidentally downgrade to the credential-independent candidate path.
  const candidateBuild = !releaseBuild && environment.ROACHNET_CANDIDATE_BUILD === '1'
  return {
    releaseBuild,
    candidateBuild,
    pinnedRuntimeBuild: releaseBuild || candidateBuild,
  }
}

const { releaseBuild, candidateBuild, pinnedRuntimeBuild } = resolveBuildModes()
const codesignIdentity = releaseBuild ? process.env.ROACHNET_CODESIGN_IDENTITY?.trim() || '' : ''
const notaryProfile = process.env.ROACHNET_NOTARY_PROFILE?.trim() || ''
const notaryKeychain = process.env.ROACHNET_NOTARY_KEYCHAIN?.trim() || ''
const skipDmg = process.env.ROACHNET_SKIP_DMG === '1'
const nativeRuntimeExecutableName = 'roachnet-runtime'
const requireAppleSiliconNativeBuild = process.env.ROACHNET_REQUIRE_APPLE_SILICON_NATIVE !== '0'
const roachSpeechBundleProfile = (
  process.env.ROACHNET_ROACHSPEECH_BUNDLE_PROFILE?.trim() || 'baseline'
).toLowerCase()
// `core` ships the app without any speech model pack: RoachSpeech stays
// compiled in and the packs install on first use through Settings › Packs.
// Resource pack archives are still produced so the catalog can point at them.
const coreRoachSpeechBundleProfiles = new Set(['core', 'none', 'minimal'])
const isCoreRoachSpeechBundleProfile = coreRoachSpeechBundleProfiles.has(roachSpeechBundleProfile)
const skipRoachSpeechPackArchives = process.env.ROACHNET_SKIP_ROACHSPEECH_PACK_ARCHIVES === '1'
const baselineRoachSpeechPackIDs = new Set([
  'roachwhisper-openai-whisper-base-en-coreml',
  'roachvoice-kokoro-82m-int8-coreml',
])
const notarizationSubmissions = []
// ROA-40: every RoachSpeech pack the build bundles or archives must match the
// committed per-file digests. ROACHNET_ALLOW_UNPINNED_ROACHSPEECH=1 skips the
// check for local experiments only; release and candidate builds ignore it.
const roachSpeechDigestManifestPath = path.join(repoRoot, 'docs', 'release-gates', 'roachspeech-pack-digests.json')
const allowUnpinnedRoachSpeech = !pinnedRuntimeBuild && process.env.ROACHNET_ALLOW_UNPINNED_ROACHSPEECH === '1'
// `upstream` checks only the files that came byte for byte from the pinned
// Hugging Face commits. The hosted stage job re-imports the packs, which
// rewrites the importer's own files (timestamps, compiled models), so it uses
// this scope; a build from the release Mac's cache checks every file.
const roachSpeechDigestScope = process.env.ROACHNET_ROACHSPEECH_DIGEST_SCOPE === 'upstream' ? 'upstream' : 'all'

async function requireRecordedRoachSpeechPack(packID, packRoot) {
  if (allowUnpinnedRoachSpeech) {
    console.warn(`RoachSpeech ${packID}: digest check skipped (ROACHNET_ALLOW_UNPINNED_ROACHSPEECH=1).`)
    return
  }
  const count = roachSpeechDigestScope === 'upstream'
    ? await verifyImportedUpstreamFiles(roachSpeechDigestManifestPath, packID, packRoot)
    : await verifyPackAgainstManifest(readDigestManifest(roachSpeechDigestManifestPath), packID, packRoot)
  if (count === 0) throw new Error(`RoachSpeech pack ${packID} has no recorded digests.`)
  console.log(`RoachSpeech ${packID}: ${count} files match the recorded digests (${roachSpeechDigestScope}).`)
}

if (!/^\d+$/.test(appBuildNumber)) {
  throw new Error('package.json buildNumber must be a positive integer for native packaging.')
}

async function sha256File(filePath) {
  const hash = createHash('sha256')
  await new Promise((resolve, reject) => {
    const stream = createReadStream(filePath)
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('error', reject)
    stream.on('end', resolve)
  })
  return hash.digest('hex')
}

async function requireFileSha256(filePath, expectedSha256, label) {
  if (!/^[a-f0-9]{64}$/i.test(String(expectedSha256 || ''))) {
    throw new Error(`${label} does not have a reviewed SHA-256 pin.`)
  }
  const actualSha256 = await sha256File(filePath)
  if (actualSha256 !== expectedSha256.toLowerCase()) {
    throw new Error(`${label} checksum mismatch. Expected ${expectedSha256}, found ${actualSha256}.`)
  }
}

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

const supportedBuildNodeMajorRange = { minimum: 26, maximumExclusive: 27 }

function nodeMajorVersionIsSupported(version) {
  const major = Number.parseInt(String(version || '').replace(/^v/, '').split('.')[0], 10)
  return (
    Number.isSafeInteger(major) &&
    major >= supportedBuildNodeMajorRange.minimum &&
    major < supportedBuildNodeMajorRange.maximumExclusive
  )
}

function getPreferredNodeBinary() {
  const currentNodeBinary = process.execPath
  if (currentNodeBinary && existsSync(currentNodeBinary) && nodeMajorVersionIsSupported(process.versions.node)) {
    return currentNodeBinary
  }

  for (const candidate of [
    '/opt/homebrew/opt/node/bin/node',
    '/opt/homebrew/opt/node@26/bin/node',
    '/usr/local/opt/node/bin/node',
    '/usr/local/opt/node@26/bin/node',
  ]) {
    if (existsSync(candidate)) {
      return candidate
    }
  }

  return process.execPath
}

async function prepareInstallerContainedTooling(installerAssetsPath) {
  // RoachNet runs local models on its own engine (RoachInference) and ships no
  // Node payloads: no Ollama runner and no OpenClaw package. Clear what older
  // builds left behind.
  for (const stale of ['bundled-ollama.tar.gz', 'bundled-ollama', 'bundled-openclaw.tar.gz', 'openclaw-deferred.marker']) {
    discardPath(path.join(installerAssetsPath, stale))
  }
  for (const stale of ['bundled-ollama', 'bundled-openclaw']) {
    discardPath(path.join(repoRoot, 'native', 'macos', '.cache', stale))
  }
}

function assertAppleSiliconNativeBuildHost() {
  if (!requireAppleSiliconNativeBuild || process.platform !== 'darwin') {
    return
  }

  if (process.arch !== 'arm64') {
    throw new Error(
      'RoachNet native macOS release builds must run under native arm64 Node on Apple Silicon. ' +
        'Set ROACHNET_REQUIRE_APPLE_SILICON_NATIVE=0 only for local Intel/Rosetta diagnostics.'
    )
  }
}

async function verifyAppleSiliconExecutable(executablePath, label) {
  if (!requireAppleSiliconNativeBuild || process.platform !== 'darwin') {
    return
  }

  const { stdout } = await run('lipo', ['-archs', executablePath], { stdio: 'pipe' })
  const archs = stdout.trim().split(/\s+/).filter(Boolean)
  if (archs.length !== 1 || archs[0] !== 'arm64') {
    throw new Error(`${label} must be a single-architecture arm64 executable for this release; found: ${archs.join(', ') || 'none'}.`)
  }
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

async function verifyNativeRuntimeHelper(bundlePath, label) {
  const helperPath = path.join(bundlePath, 'Contents', 'Helpers', nativeRuntimeExecutableName)
  if (!existsSync(helperPath)) {
    throw new Error(`${label} is missing the native runtime helper at ${helperPath}`)
  }
  await verifyAppleSiliconExecutable(helperPath, `${label} native runtime helper`)
  const libraries = await inspectDynamicLibraries(helperPath)
  const foreignLibraries = libraries.filter(
    (libraryPath) => !libraryPath.startsWith('/usr/lib/') && !libraryPath.startsWith('/System/Library/')
  )
  if (foreignLibraries.length > 0) {
    throw new Error(
      `${label} native runtime helper links non-system libraries:\n${foreignLibraries.join('\n')}`
    )
  }
}

// Node, JavaScript and RoachNet's own source stay out of every bundle: the
// apps run only Swift code (ROA-78).
const forbiddenBundleNames = new Set(['node_modules', 'RoachNetSource', 'RoachNetSource.tar.gz'])
const forbiddenBundleExtensions = new Set(['.js', '.mjs', '.cjs', '.node'])

function assertNoNodeOrJavaScript(bundlePath, label) {
  const found = []
  const walk = (folder) => {
    for (const entry of readdirSync(folder, { withFileTypes: true })) {
      const entryPath = path.join(folder, entry.name)
      const shown = path.relative(bundlePath, entryPath)
      if (forbiddenBundleNames.has(entry.name) || forbiddenBundleExtensions.has(path.extname(entry.name).toLowerCase())) {
        found.push(shown)
      } else if (entry.name === 'node' && !entry.isDirectory()) {
        found.push(shown)
      } else if (entry.isDirectory() && !entry.isSymbolicLink()) {
        walk(entryPath)
      }
    }
  }
  walk(bundlePath)
  if (found.length > 0) {
    throw new Error(`${label} carries Node, JavaScript or RoachNet source it must not ship:\n${found.slice(0, 20).join('\n')}`)
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

  await verifyNativeRuntimeHelper(desktopBundlePath, 'RoachNet')
  await verifyNativeRuntimeHelper(setupBundlePath, 'RoachNet Setup')

  const runtimeCatalogPath = path.join(desktopBundlePath, 'Contents', 'Resources', 'RoachNetRuntimeData', 'collections', 'maps.json')
  if (!existsSync(runtimeCatalogPath)) {
    throw new Error(`Missing native runtime catalog data at ${runtimeCatalogPath}`)
  }

  assertNoNodeOrJavaScript(desktopBundlePath, 'RoachNet')
  assertNoNodeOrJavaScript(setupBundlePath, 'RoachNet Setup')
  for (const [bundlePath, label] of [[desktopBundlePath, 'RoachNet'], [setupBundlePath, 'RoachNet Setup']]) {
    if (!existsSync(path.join(bundlePath, 'Contents', 'Resources', 'LICENSE'))) {
      throw new Error(`${label} is missing Contents/Resources/LICENSE`)
    }
  }

  if (!existsSync(installerAssetArchivePath)) {
    throw new Error(`Missing installer asset archive at ${installerAssetArchivePath}`)
  }
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

      if (path.extname(entry.name) === '.dylib') {
        targets.push(entryPath)
      }
    }
  }

  return targets.sort((left, right) => right.length - left.length)
}

async function signHelperExecutables(bundlePath) {
  const helpersPath = path.join(bundlePath, 'Contents', 'Helpers')
  if (!existsSync(helpersPath)) {
    return
  }
  for (const entry of await readdir(helpersPath, { withFileTypes: true })) {
    if (entry.isFile()) {
      await signCodeObject(path.join(helpersPath, entry.name))
    }
  }
}

async function signAppBundle(bundlePath) {
  await signHelperExecutables(bundlePath)
  const signTargetRoots = [
    path.join(bundlePath, 'Contents', 'MacOS'),
    path.join(bundlePath, 'Contents', 'Frameworks'),
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

async function clearBundleLaunchMetadata(bundlePath) {
  await clearLaunchMetadata(bundlePath, {
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

function roachSpeechPackIsBundled(packID) {
  if (isCoreRoachSpeechBundleProfile) {
    return false
  }
  if (['full', 'complete', 'all'].includes(roachSpeechBundleProfile)) {
    return true
  }

  return baselineRoachSpeechPackIDs.has(packID)
}

function listRoachSpeechModelPacks(sourcePath) {
  const modelPacksPath = path.join(sourcePath, 'ModelPacks')
  if (!existsSync(modelPacksPath)) {
    return []
  }

  return readdirSync(modelPacksPath, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
}

function writeRoachSpeechRuntimeManifest(destinationPath, bundledPackIDs, optionalPackIDs) {
  writeFileSync(
    path.join(destinationPath, 'RUNTIME.md'),
    [
      '# RoachSpeech Runtime',
      '',
      `Bundle profile: ${roachSpeechBundleProfile}`,
      '',
      'RoachSpeech is Apple Silicon native in this build:',
      '',
      '- RoachWhisper Core ML for local STT and transcript sidecars.',
      '- RoachVoice Core ML for local TTS and read-aloud.',
      '- Optional RoachVoice packs install into the user model shelf instead of bloating every installer.',
      '',
      'Bundled model packs:',
      ...bundledPackIDs.map((packID) => `- ${packID}`),
      '',
      'Optional first-party model packs:',
      ...(optionalPackIDs.length > 0 ? optionalPackIDs.map((packID) => `- ${packID}`) : ['- none']),
      '',
      'Release gates fail if whisper-cli, Piper, or C/C++ speech engine payloads are present.',
      '',
    ].join('\n'),
    'utf8'
  )
}

async function copyBundledRoachSpeechRuntime(resourcesPath) {
  const sourcePath = path.join(packagePath, 'Vendor', 'RoachSpeech')
  const destinationPath = path.join(resourcesPath, 'RoachSpeech')
  if (!existsSync(sourcePath)) {
    mkdirSync(destinationPath, { recursive: true })
    writeRoachSpeechRuntimeManifest(destinationPath, [], [])
    return
  }

  const allPackIDs = listRoachSpeechModelPacks(sourcePath)
  const bundledPackIDs = allPackIDs.filter(roachSpeechPackIsBundled)
  const optionalPackIDs = allPackIDs.filter((packID) => !bundledPackIDs.includes(packID))

  if (allPackIDs.length > 0 && bundledPackIDs.length === 0 && !isCoreRoachSpeechBundleProfile) {
    throw new Error(
      `RoachSpeech bundle profile "${roachSpeechBundleProfile}" did not select any model packs.`
    )
  }

  console.log(
    `Bundling RoachSpeech ${roachSpeechBundleProfile} runtime into ${destinationPath} (${bundledPackIDs.length}/${allPackIDs.length} packs)...`
  )
  discardPath(destinationPath)
  mkdirSync(path.join(destinationPath, 'ModelPacks'), { recursive: true })
  for (const packID of bundledPackIDs) {
    await requireRecordedRoachSpeechPack(packID, path.join(sourcePath, 'ModelPacks', packID))
    await copyTreeFast(
      path.join(sourcePath, 'ModelPacks', packID),
      path.join(destinationPath, 'ModelPacks', packID)
    )
  }
  writeRoachSpeechRuntimeManifest(destinationPath, bundledPackIDs, optionalPackIDs)
  await clearLaunchMetadata(destinationPath, { recursive: true })
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

async function createRoachSpeechPackArchive(packID) {
  const sourcePath = path.join(packagePath, 'Vendor', 'RoachSpeech', 'ModelPacks', packID)
  if (!existsSync(sourcePath)) {
    return null
  }

  await requireRecordedRoachSpeechPack(packID, sourcePath)
  const archivePath = path.join(distPath, 'RoachSpeechPacks', `${packID}.zip`)
  discardPath(archivePath)
  mkdirSync(path.dirname(archivePath), { recursive: true })
  await run(
    'ditto',
    ['-c', '-k', '--sequesterRsrc', '--keepParent', sourcePath, archivePath],
    { stdio: 'pipe' }
  )
  await writeSha256Sidecar(archivePath)
  return archivePath
}

async function createRoachSpeechPackArchives() {
  if (skipRoachSpeechPackArchives) {
    return []
  }

  const sourcePath = path.join(packagePath, 'Vendor', 'RoachSpeech')
  const packIDs = listRoachSpeechModelPacks(sourcePath)
  if (packIDs.length === 0) {
    return []
  }

  console.log(`Creating RoachSpeech pack archives: ${packIDs.join(', ')}`)
  const archives = []
  for (const packID of packIDs) {
    const archivePath = await createRoachSpeechPackArchive(packID)
    if (archivePath) {
      archives.push(archivePath)
    }
  }
  return archives
}

/**
 * Keeps symbols for crash reports next to the build (never shipped), then
 * strips debug info from every executable in a bundle. The debug map holds
 * absolute paths from the build Mac (its volume and workspace folders), which
 * have no place in a public download.
 */
async function writeDebugSymbols(binPath) {
  const symbolsRoot = path.join(packagePath, 'dist-symbols', `${appVersion}-${appBuildNumber}`)
  mkdirSync(symbolsRoot, { recursive: true })
  for (const name of ['RoachNetApp', 'RoachNetSetup', nativeRuntimeExecutableName]) {
    const binary = path.join(binPath, name)
    if (!existsSync(binary)) continue
    try {
      await run('xcrun', ['dsymutil', binary, '-o', path.join(symbolsRoot, `${name}.dSYM`)], { stdio: 'pipe' })
    } catch (error) {
      console.warn(`Couldn't keep debug symbols for ${name}: ${error.message}`)
    }
  }
}

async function stripBundleExecutables(contentsPath) {
  for (const folder of ['MacOS', 'Helpers']) {
    const root = path.join(contentsPath, folder)
    if (!existsSync(root)) continue
    for (const entry of await readdir(root, { withFileTypes: true })) {
      if (!entry.isFile()) continue
      const file = path.join(root, entry.name)
      const kind = await run('file', ['-b', file], { stdio: 'pipe' })
      if (!kind.stdout.includes('Mach-O')) continue
      // -S drops the debug map (and the paths in it); global symbols stay.
      await run('xcrun', ['strip', '-S', file], { stdio: 'pipe' })
    }
  }
}

async function auditReleasePrivacy(targets) {
  const result = spawnSync(process.execPath, [path.join(repoRoot, 'scripts', 'audit-release-privacy.mjs'), ...targets], { encoding: 'utf8' })
  process.stdout.write(result.stdout || '')
  if (result.status !== 0) {
    process.stderr.write(result.stderr || '')
    throw new Error('The built apps carry details of this Mac; see the privacy audit above.')
  }
}

async function copyNativeRuntimeHelper(binPath, contentsPath) {
  const sourcePath = path.join(binPath, nativeRuntimeExecutableName)
  if (!existsSync(sourcePath)) {
    throw new Error(`Missing native runtime helper at ${sourcePath}`)
  }
  const helpersPath = path.join(contentsPath, 'Helpers')
  mkdirSync(helpersPath, { recursive: true })
  const destinationPath = path.join(helpersPath, nativeRuntimeExecutableName)
  await cp(sourcePath, destinationPath)
  chmodSync(destinationPath, 0o755)
}

async function copyNativeRuntimeData(resourcesPath) {
  const dataRoot = path.join(resourcesPath, 'RoachNetRuntimeData')
  discardPath(dataRoot)
  mkdirSync(dataRoot, { recursive: true })
  await cp(path.join(repoRoot, 'collections'), path.join(dataRoot, 'collections'), { recursive: true })
  writeFileSync(
    path.join(dataRoot, 'package.json'),
    `${JSON.stringify({ name: 'roachnet', version: appVersion, buildNumber: Number(appBuildNumber) }, null, 2)}\n`,
    'utf8'
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
  // Each app carries the repository license (Apache-2.0).
  await cp(path.join(repoRoot, 'LICENSE'), path.join(resourcesPath, 'LICENSE'))

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
  <string>${appBuildNumber}</string>
${sourceCommit ? `  <key>RoachNetSourceCommit</key>\n  <string>${sourceCommit}</string>\n` : ''}  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>RoachNet uses the microphone for local voice prompts inside RoachClaw.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>RoachNet turns speech into local prompts so RoachClaw and Dev Studio can stay hands-free when you want them to.</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>RoachNet uses Bluetooth only to receive RoachPhone GPS packets for local in-app map tracking.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>RoachNet uses Bluetooth only to receive RoachPhone GPS packets for local in-app map tracking.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>RoachNet Cluster connects to your other Macs on this network, when you turn it on, so they can run a model together.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_roachnet-cluster._tcp</string>
  </array>
  ${iconPath ? '<key>CFBundleIconFile</key>\n  <string>RoachNet</string>' : ''}
  ${urlSchemesPlist}
</dict>
</plist>
`

  writeFileSync(path.join(contentsPath, 'Info.plist'), plist, 'utf8')
  await stripBundleExecutables(contentsPath)
  console.log(`Signing ${name}...`)

  await signAppBundle(bundlePath)
  await clearBundleLaunchMetadata(bundlePath)

  return bundlePath
}

async function notarizeArtifact(artifactPath) {
  if (candidateBuild) {
    return
  }

  if (!codesignIdentity || !notaryProfile) {
    if (releaseBuild) {
      throw new Error('Public release builds require Developer ID signing and a configured notary profile.')
    }
    return
  }

  const submitArgs = [
    'notarytool',
    'submit',
    artifactPath,
    '--keychain-profile',
    notaryProfile,
    '--wait',
    '--output-format',
    'json',
  ]
  if (notaryKeychain) {
    submitArgs.push('--keychain', notaryKeychain)
  }

  const result = await run('xcrun', submitArgs, { stdio: 'pipe' })
  notarizationSubmissions.push(parseAcceptedNotarySubmission(result.stdout, artifactPath))

  await run('xcrun', ['stapler', 'staple', artifactPath], { stdio: 'pipe' })
  await run('xcrun', ['stapler', 'validate', artifactPath], { stdio: 'pipe' })
}

async function main() {
  if (releaseBuild && (!codesignIdentity || !notaryProfile || skipDmg)) {
    throw new Error('Public release mode requires Developer ID signing, notarization, and DMG creation.')
  }
  if (candidateBuild) {
    console.log('Building credential-independent candidate artifacts with checksum-pinned runtimes; this is not a notarized public release.')
  }
  assertAppleSiliconNativeBuildHost()
  mkdirSync(distPath, { recursive: true })
  await ensureLaunchGuideVideo()
  const binPath = await buildSwiftPackage()
  await writeDebugSymbols(binPath)
  const iconPath = await buildIcns()
  const desktopAppBundlePath = path.join(distPath, 'RoachNet.app')

  const apps = [
    {
      name: 'RoachNet',
      executable: path.join(binPath, 'RoachNetApp'),
      identifier: 'com.roachwares.roachnet',
      urlSchemes: ['roachnet'],
      prepareResources: async ({ contentsPath, resourcesPath }) => {
        await copyNativeRuntimeHelper(binPath, contentsPath)
        await copyNativeRuntimeData(resourcesPath)
        await copyBundledRoachSpeechRuntime(resourcesPath)
      },
    },
    {
      name: 'RoachNet Setup',
      executable: path.join(binPath, 'RoachNetSetup'),
      identifier: 'com.roachwares.roachnet.setup',
      prepareResources: async ({ contentsPath, resourcesPath }) => {
        await copyNativeRuntimeHelper(binPath, contentsPath)
        const installerAssetsPath = path.join(resourcesPath, 'InstallerAssets')
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

  await verifyAppleSiliconExecutable(path.join(binPath, nativeRuntimeExecutableName), 'roachnet-runtime')
  for (const app of apps) {
    if (!existsSync(app.executable)) {
      throw new Error(`Missing native executable at ${app.executable}`)
    }
    await verifyAppleSiliconExecutable(app.executable, app.name)
  }

  const builtBundles = []
  for (const app of apps) {
    builtBundles.push(await bundleApp({ ...app, iconPath }))
  }

  builtBundles.push(...(await createRoachSpeechPackArchives()))
  await verifyBuiltArtifacts()
  await auditReleasePrivacy(builtBundles)

  const setupAppBundlePath = builtBundles.find((bundlePath) => bundlePath.endsWith('RoachNet Setup.app'))
  if (setupAppBundlePath) {
    await notarizeArtifact(setupAppBundlePath)
    if (!skipDmg) {
      const dmgPath = await createSetupDmg(setupAppBundlePath)
      await notarizeArtifact(dmgPath)
      await auditReleasePrivacy([dmgPath])
      await writeSha256Sidecar(dmgPath)
      builtBundles.push(dmgPath)
    }
  }

  if (releaseBuild) {
    const dmgSubmission = notarizationSubmissions.find(
      (entry) => entry.artifact === 'RoachNet-Setup-macOS.dmg'
    )
    if (!dmgSubmission) {
      throw new Error('Public release build is missing candidate-specific DMG notarization evidence.')
    }
    const evidenceRoot = path.join(distPath, 'release-evidence')
    mkdirSync(evidenceRoot, { recursive: true })
    writeFileSync(
      path.join(evidenceRoot, 'notarization-submissions.json'),
      `${JSON.stringify({
        schema: 'org.roachnet.notarization-submissions.v1',
        submissions: notarizationSubmissions,
      }, null, 2)}\n`,
      'utf8'
    )
  }

  for (const bundle of builtBundles) {
    process.stdout.write(`${bundle}\n`)
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.message)
    process.exitCode = 1
  })
}
