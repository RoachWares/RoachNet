#!/usr/bin/env node

import { access, mkdir, readFile, readdir, rm, stat, writeFile, copyFile, cp, rename } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import path from 'node:path'
import process from 'node:process'
import { spawn } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const adminDir = path.join(repoRoot, 'admin')
const buildDir = path.join(adminDir, 'build')
const runtimeCacheDir = path.join(adminDir, '.runtime-build-cache')
const cachedNodeModulesPath = path.join(runtimeCacheDir, 'node_modules')
const cachedLockHashPath = path.join(runtimeCacheDir, 'package-lock.sha256')
const buildStampPath = path.join(buildDir, '.roachnet-build-stamp.json')
const swcModuleUrl = pathToFileURL(path.join(adminDir, 'node_modules', '@swc', 'core', 'index.js')).href
const viteNodeModuleUrl = pathToFileURL(
  path.join(adminDir, 'node_modules', 'vite', 'dist', 'node', 'index.js')
).href

const transpiledRootFiles = new Set([
  'adonisrc.ts',
])
const copiedRootFiles = new Set([
  'package.json',
  'package-lock.json',
  'ace.js',
])
const transpileDirectories = ['bin', 'app', 'config', 'constants', 'database', 'providers', 'start', 'types', 'util']
const copyDirectories = ['docs', 'public', 'resources', 'views']

function shouldSkip(relativePath) {
  if (!relativePath) {
    return false
  }

  const normalized = relativePath.split(path.sep).join('/')
  if (
    normalized === '.env' ||
    normalized.endsWith('.log') ||
    normalized.endsWith('.tsbuildinfo') ||
    normalized.includes('/storage/logs/') ||
    normalized.includes('/storage/tmp/')
  ) {
    return true
  }

  return false
}

function shouldTranspile(relativePath) {
  return (
    (relativePath.endsWith('.ts') || relativePath.endsWith('.tsx')) &&
    !relativePath.endsWith('.d.ts')
  )
}

function outputPathFor(relativePath) {
  if (relativePath.endsWith('.tsx')) {
    return path.join(buildDir, relativePath.slice(0, -4) + '.js')
  }

  if (relativePath.endsWith('.ts')) {
    return path.join(buildDir, relativePath.slice(0, -3) + '.js')
  }

  return path.join(buildDir, relativePath)
}

async function ensureParent(filePath) {
  await mkdir(path.dirname(filePath), { recursive: true })
}

async function pathExists(filePath) {
  try {
    await access(filePath)
    return true
  } catch {
    return false
  }
}

function getPreferredNodeBinary() {
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/node'
  return process.platform === 'darwin' ? macHomebrewNode22 : process.execPath
}

function getPreferredNpmBinary() {
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/npm'
  return process.platform === 'darwin' ? macHomebrewNode22 : 'npm'
}

async function run(command, args, options = {}) {
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
        return
      }

      reject(new Error(`${command} ${args.join(' ')} failed with exit code ${code}\n${stderr}`))
    })
  })
}

async function buildFrontendAssets() {
  const manifestPath = path.join(adminDir, 'public', 'assets', '.vite', 'manifest.json')
  if (process.env.ROACHNET_FORCE_VITE_BUILD !== '1') {
    try {
      await access(manifestPath)
      console.log(`Using existing frontend assets at ${manifestPath}`)
      return
    } catch {
      // Fall through to a fresh build when no prior assets exist.
    }
  }

  const { build } = await import(viteNodeModuleUrl)
  await build({
    root: adminDir,
    configFile: path.join(adminDir, 'vite.config.ts'),
    mode: 'production',
    clearScreen: false,
    logLevel: 'info',
    envFile: false,
  })
}

async function transpileFile(relativePath) {
  const sourcePath = path.join(adminDir, relativePath)
  const outputPath = outputPathFor(relativePath)
  const source = await readFile(sourcePath, 'utf8')
  const { transform } = await import(swcModuleUrl)
  const result = await transform(source, {
    filename: sourcePath,
    sourceMaps: false,
    module: {
      type: 'es6',
    },
    jsc: {
      target: 'es2022',
      keepClassNames: true,
      parser: {
        syntax: 'typescript',
        tsx: relativePath.endsWith('.tsx'),
        decorators: true,
        dynamicImport: true,
      },
      transform: {
        legacyDecorator: true,
        decoratorMetadata: true,
        react: relativePath.endsWith('.tsx')
          ? {
              runtime: 'automatic',
            }
          : undefined,
      },
    },
  })

  await ensureParent(outputPath)
  await writeFile(outputPath, result.code, 'utf8')
}

async function copyFileIntoBuild(relativePath) {
  const sourcePath = path.join(adminDir, relativePath)
  const outputPath = outputPathFor(relativePath)
  await ensureParent(outputPath)
  await copyFile(sourcePath, outputPath)
}

async function walk(relativePath = '') {
  const directoryPath = path.join(adminDir, relativePath)
  const entries = await readdir(directoryPath, { withFileTypes: true })

  for (const entry of entries) {
    const entryRelativePath = relativePath ? path.join(relativePath, entry.name) : entry.name

    if (shouldSkip(entryRelativePath)) {
      continue
    }

    if (entry.isDirectory()) {
      await walk(entryRelativePath)
      continue
    }

    if (!entry.isFile()) {
      continue
    }

    if (
      relativePath === '' &&
      !copiedRootFiles.has(entry.name) &&
      !transpiledRootFiles.has(entry.name)
    ) {
      continue
    }

    if (shouldTranspile(entryRelativePath)) {
      await transpileFile(entryRelativePath)
    } else {
      await copyFileIntoBuild(entryRelativePath)
    }
  }
}

async function readLockfileHash() {
  const lockfile = await readFile(path.join(adminDir, 'package-lock.json'))
  return createHash('sha256').update(lockfile).digest('hex')
}

async function readCachedLockHash() {
  try {
    return (await readFile(cachedLockHashPath, 'utf8')).trim()
  } catch {
    return null
  }
}

async function collectBuildTreeHashParts(currentPath, relativePath = '.') {
  const entries = await readdir(currentPath, { withFileTypes: true })
  const parts = []

  for (const entry of entries) {
    const nextRelativePath = path.join(relativePath, entry.name)
    const normalized = nextRelativePath.split(path.sep).join('/')

    if (
      normalized === 'node_modules' ||
      normalized.startsWith('node_modules/') ||
      normalized === 'public/assets' ||
      normalized.startsWith('public/assets/')
    ) {
      continue
    }

    const fullPath = path.join(currentPath, entry.name)

    if (entry.isDirectory()) {
      parts.push(...(await collectBuildTreeHashParts(fullPath, nextRelativePath)))
      continue
    }

    if (!entry.isFile()) {
      continue
    }

    parts.push(
      `${nextRelativePath}\n${createHash('sha256').update(await readFile(fullPath)).digest('hex')}`
    )
  }

  return parts
}

async function preserveExistingRuntimeDependencies() {
  const buildNodeModulesPath = path.join(buildDir, 'node_modules')
  if (!(await pathExists(buildNodeModulesPath))) {
    return
  }

  await mkdir(runtimeCacheDir, { recursive: true })
  await rm(cachedNodeModulesPath, { recursive: true, force: true })
  await rename(buildNodeModulesPath, cachedNodeModulesPath)
}

async function invalidateCachedRuntimeDependencies() {
  await rm(cachedNodeModulesPath, { recursive: true, force: true })
  await rm(cachedLockHashPath, { force: true })
}

async function restoreOrInstallRuntimeDependencies() {
  const buildNodeModulesPath = path.join(buildDir, 'node_modules')
  const currentLockHash = await readLockfileHash()
  const cachedLockHash = await readCachedLockHash()
  const hasCachedNodeModules = await pathExists(cachedNodeModulesPath)
  const canReuseCache = hasCachedNodeModules && cachedLockHash === currentLockHash

  if (!canReuseCache && (hasCachedNodeModules || cachedLockHash)) {
    console.log('Discarding stale runtime dependency cache...')
    await invalidateCachedRuntimeDependencies()
  }

  if (await pathExists(buildNodeModulesPath)) {
    return
  }

  if (await pathExists(cachedNodeModulesPath)) {
    console.log('Restoring cached production runtime dependencies...')
    await rename(cachedNodeModulesPath, buildNodeModulesPath)
    return
  }

  console.log('Installing production runtime dependencies...')
  await run(getPreferredNpmBinary(), ['ci', '--omit=dev'], {
    cwd: buildDir,
    env: {
      ...process.env,
      NODE_ENV: 'production',
      PATH: `${path.dirname(getPreferredNodeBinary())}:${process.env.PATH || ''}`,
    },
  })

  await mkdir(runtimeCacheDir, { recursive: true })
  await writeFile(cachedLockHashPath, currentLockHash + '\n', 'utf8')
}

async function writeBuildStamp() {
  const manifestPath = path.join(buildDir, 'public', 'assets', '.vite', 'manifest.json')
  const buildPackageJsonPath = path.join(buildDir, 'package.json')
  const treeHash = createHash('sha256')
    .update((await collectBuildTreeHashParts(buildDir)).join('\n---\n'))
    .digest('hex')
  const buildStamp = {
    generatedAt: new Date().toISOString(),
    dependencyHash: await readLockfileHash(),
    serverEntrypointHash: createHash('sha256').update(await readFile(path.join(buildDir, 'bin', 'server.js'))).digest('hex'),
    workerEntrypointHash: createHash('sha256').update(await readFile(path.join(buildDir, 'bin', 'worker.js'))).digest('hex'),
    packageJsonHash: createHash('sha256').update(await readFile(buildPackageJsonPath)).digest('hex'),
    assetManifestHash: (await pathExists(manifestPath))
      ? createHash('sha256').update(await readFile(manifestPath)).digest('hex')
      : null,
    treeHash,
  }

  await writeFile(buildStampPath, JSON.stringify(buildStamp, null, 2) + '\n', 'utf8')
}

async function main() {
  await preserveExistingRuntimeDependencies()
  await rm(buildDir, { recursive: true, force: true })
  await mkdir(buildDir, { recursive: true })
  console.log('Building frontend assets...')
  process.env.NODE_ENV = 'production'
  process.env.NODE_DISABLE_COMPILE_CACHE = '1'
  process.env.PATH = `${path.dirname(getPreferredNodeBinary())}:${process.env.PATH || ''}`
  await buildFrontendAssets()
  console.log('Preparing root files...')

  for (const rootFile of copiedRootFiles) {
    await copyFileIntoBuild(rootFile)
  }

  for (const rootFile of transpiledRootFiles) {
    await transpileFile(rootFile)
  }

  for (const directory of transpileDirectories) {
    console.log(`Transpiling ${directory}...`)
    await walk(directory)
  }

  for (const directory of copyDirectories) {
    console.log(`Copying ${directory}...`)
    await cp(path.join(adminDir, directory), path.join(buildDir, directory), {
      recursive: true,
      force: true,
    })
  }

  const buildPackageJsonPath = path.join(buildDir, 'package.json')
  const buildPackageJson = JSON.parse(await readFile(buildPackageJsonPath, 'utf8'))
  buildPackageJson.scripts = {
    start: 'node bin/server.js',
  }
  await writeFile(buildPackageJsonPath, JSON.stringify(buildPackageJson, null, 2) + '\n', 'utf8')

  await restoreOrInstallRuntimeDependencies()
  await writeBuildStamp()

  const buildStat = await stat(path.join(buildDir, 'bin', 'server.js'))
  console.log(`Built admin runtime into ${buildDir} (${buildStat.size} bytes for server entrypoint)`)
}

main()
  .then(() => {
    process.exit(0)
  })
  .catch((error) => {
    console.error(error instanceof Error ? error.stack ?? error.message : error)
    process.exit(1)
  })
