#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
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
const appVersion = JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8')).version || '1.30.4'
const codesignIdentity = process.env.ROACHNET_CODESIGN_IDENTITY?.trim() || ''
const notaryProfile = process.env.ROACHNET_NOTARY_PROFILE?.trim() || ''
const notaryKeychain = process.env.ROACHNET_NOTARY_KEYCHAIN?.trim() || ''

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd || repoRoot,
      env: options.env || process.env,
      stdio: options.stdio || 'inherit',
    })

    let stdout = ''
    let stderr = ''

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
      if (code === 0) {
        resolve({ stdout, stderr })
      } else {
        reject(new Error(`${command} ${args.join(' ')} failed with exit code ${code}\n${stderr}`))
      }
    })
  })
}

function getPreferredNodeBinary() {
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/node'
  return existsSync(macHomebrewNode22) ? macHomebrewNode22 : process.execPath
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
  'native/macos/.build/',
  'native/macos/dist/',
  'native/linux/target/',
  'native/windows/bin/',
  'native/windows/obj/',
  'admin/node_modules/',
  'admin/build/',
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

async function copyBundledSourceTree(destinationPath) {
  const stagingRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-source-staging-'))
  const stagedSourcePath = path.join(stagingRoot, 'RoachNetSource')

  rmSync(destinationPath, { recursive: true, force: true })
  try {
    await syncTree(repoRoot, stagedSourcePath)
    await syncTree(stagedSourcePath, destinationPath)
  } finally {
    rmSync(stagingRoot, { recursive: true, force: true })
  }
}

async function createSetupDmg(setupAppBundlePath) {
  const dmgPath = path.join(distPath, 'RoachNet-Setup-macOS.dmg')

  rmSync(dmgPath, { force: true })
  await run(
    'hdiutil',
    [
      'create',
      '-volname',
      'RoachNet Setup',
      '-srcfolder',
      setupAppBundlePath,
      '-ov',
      '-format',
      'UDZO',
      dmgPath,
    ],
    { stdio: 'pipe' }
  )

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

async function bundleApp({ name, executable, identifier, iconPath, prepareResources }) {
  const bundlePath = path.join(distPath, `${name}.app`)
  const contentsPath = path.join(bundlePath, 'Contents')
  const macOSPath = path.join(contentsPath, 'MacOS')
  const resourcesPath = path.join(contentsPath, 'Resources')

  rmSync(bundlePath, { recursive: true, force: true })
  mkdirSync(macOSPath, { recursive: true })
  mkdirSync(resourcesPath, { recursive: true })

  await cp(executable, path.join(macOSPath, path.basename(executable)))
  await copySwiftPackageResources(executable, resourcesPath)

  if (iconPath) {
    await cp(iconPath, path.join(resourcesPath, 'RoachNet.icns'))
  }

  if (prepareResources) {
    await prepareResources({ bundlePath, contentsPath, resourcesPath })
  }

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
</dict>
</plist>
`

  writeFileSync(path.join(contentsPath, 'Info.plist'), plist, 'utf8')

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
  const binPath = await buildSwiftPackage()
  const iconPath = await buildIcns()
  const desktopAppBundlePath = path.join(distPath, 'RoachNet.app')

  const apps = [
    {
      name: 'RoachNet',
      executable: path.join(binPath, 'RoachNetApp'),
      identifier: 'com.roachwares.roachnet',
    },
    {
      name: 'RoachNet Setup',
      executable: path.join(binPath, 'RoachNetSetup'),
      identifier: 'com.roachwares.roachnet.setup',
      prepareResources: async ({ resourcesPath }) => {
        const bundledSourcePath = path.join(resourcesPath, 'RoachNetSource')
        const installerAssetsPath = path.join(resourcesPath, 'InstallerAssets')

        await copyBundledSourceTree(bundledSourcePath)
        mkdirSync(installerAssetsPath, { recursive: true })
        writeFileSync(path.join(installerAssetsPath, 'setup-assets.marker'), '', 'utf8')

        if (existsSync(desktopAppBundlePath)) {
          await cp(desktopAppBundlePath, path.join(installerAssetsPath, 'RoachNet.app'), {
            recursive: true,
            force: true,
          })
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
    const dmgPath = await createSetupDmg(setupAppBundlePath)
    await notarizeArtifact(dmgPath)
    builtBundles.push(dmgPath)
  }

  for (const bundle of builtBundles) {
    process.stdout.write(`${bundle}\n`)
  }
}

main().catch((error) => {
  console.error(error.message)
  process.exitCode = 1
})
