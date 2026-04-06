#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { cp, mkdtemp, readdir } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

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
const codesignIdentity = process.env.ROACHNET_CODESIGN_IDENTITY?.trim() || ''
const notaryProfile = process.env.ROACHNET_NOTARY_PROFILE?.trim() || ''
const notaryKeychain = process.env.ROACHNET_NOTARY_KEYCHAIN?.trim() || ''
const skipDmg = process.env.ROACHNET_SKIP_DMG === '1'

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

function serializeEnvFile(values) {
  return (
    Object.entries(values)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, value]) => `${key}=${String(value)}`)
      .join('\n') + '\n'
  )
}

function getPreferredNodeBinary() {
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/node'
  return existsSync(macHomebrewNode22) ? macHomebrewNode22 : process.execPath
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

  try {
    const { stdout } = await run(binaryPath, ['--version'], {
      stdio: 'pipe',
      timeoutMs: 4_000,
    })
    const resolvedVersion = stdout.trim()
    const expectedMajor = bundledNodeVersion.replace(/^v/, '').split('.')[0]
    const actualMajor = resolvedVersion.replace(/^v/, '').split('.')[0]
    if (actualMajor !== expectedMajor) {
      return false
    }

    if (options.requirePortable !== true || process.platform !== 'darwin') {
      return true
    }

    const libraries = await inspectDynamicLibraries(binaryPath)
    return libraries.every((libraryPath) => isAllowedBundledLibraryPath(libraryPath, runtimeRoot))
  } catch {
    return false
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

async function signAppBundle(bundlePath) {
  const args = ['--force', '--deep', '--sign', codesignIdentity || '-', bundlePath]

  if (codesignIdentity) {
    args.splice(2, 0, '--options', 'runtime', '--timestamp')
  }

  await run('codesign', args, { stdio: 'pipe' })
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
  // On APFS this avoids a full byte-for-byte duplicate pass for large bundle trees.
  await run('ditto', ['--clone', sourcePath, destinationPath], { stdio: 'pipe' })
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
  await syncTree(repoRoot, destinationPath)

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
  ${iconPath ? '<key>CFBundleIconFile</key>\n  <string>RoachNet</string>' : ''}
  ${urlSchemesPlist}
</dict>
</plist>
`

  writeFileSync(path.join(contentsPath, 'Info.plist'), plist, 'utf8')
  console.log(`Signing ${name}...`)

  await signAppBundle(bundlePath)

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
        const bundledSourcePath = path.join(resourcesPath, 'RoachNetSource')
        await copyBundledSourceTree(bundledSourcePath)
      },
    },
    {
      name: 'RoachNet Setup',
      executable: path.join(binPath, 'RoachNetSetup'),
      identifier: 'com.roachwares.roachnet.setup',
      prepareResources: async ({ resourcesPath }) => {
        await copyBundledNodeRuntime(bundledNodeRuntimePath, resourcesPath)
        const bundledSourcePath = path.join(resourcesPath, 'RoachNetSource')
        const installerAssetsPath = path.join(resourcesPath, 'InstallerAssets')

        await copyBundledSourceTree(bundledSourcePath)
        mkdirSync(installerAssetsPath, { recursive: true })
        writeFileSync(path.join(installerAssetsPath, 'setup-assets.marker'), '', 'utf8')

        if (existsSync(desktopAppBundlePath)) {
          await copyTreeFast(desktopAppBundlePath, path.join(installerAssetsPath, 'RoachNet.app'))
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

  const setupAppBundlePath = builtBundles.find((bundlePath) => bundlePath.endsWith('RoachNet Setup.app'))
  if (setupAppBundlePath) {
    await notarizeArtifact(setupAppBundlePath)
    if (!skipDmg) {
      const dmgPath = await createSetupDmg(setupAppBundlePath)
      await notarizeArtifact(dmgPath)
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
