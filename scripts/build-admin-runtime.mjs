#!/usr/bin/env node

import { access, mkdir, readFile, readdir, rm, stat, writeFile, copyFile, cp } from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath, pathToFileURL } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const adminDir = path.join(repoRoot, 'admin')
const buildDir = path.join(adminDir, 'build')
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

function getPreferredNodeBinary() {
  const macHomebrewNode22 = '/opt/homebrew/opt/node@22/bin/node'
  return process.platform === 'darwin' ? macHomebrewNode22 : process.execPath
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

async function main() {
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

  const buildStat = await stat(path.join(buildDir, 'bin', 'server.js'))
  console.log(`Built admin runtime into ${buildDir} (${buildStat.size} bytes for server entrypoint)`)
}

main().catch((error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : error)
  process.exitCode = 1
})
