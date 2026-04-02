#!/usr/bin/env node

import fs from 'node:fs/promises'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { fileURLToPath, pathToFileURL } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const adminDir = path.join(repoRoot, 'admin')
const buildDir = path.join(adminDir, 'build')
const swcModuleUrl = pathToFileURL(path.join(adminDir, 'node_modules', '@swc', 'core', 'index.js')).href

const files = [
  'app/controllers/chats_controller.ts',
  'app/controllers/home_controller.ts',
  'app/services/chat_service.ts',
  'app/services/docker_service.ts',
  'app/services/ollama_service.ts',
  'app/services/roachclaw_service.ts',
  'constants/ollama.ts',
  'app/exceptions/handler.ts',
]

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
  await fs.mkdir(path.dirname(filePath), { recursive: true })
}

async function transpile(relativePath) {
  const sourcePath = path.join(adminDir, relativePath)
  const outputPath = outputPathFor(relativePath)
  const source = await fs.readFile(sourcePath, 'utf8')
  const { transform } = await import(swcModuleUrl)
  const result = await transform(source, {
    filename: sourcePath,
    sourceMaps: false,
    module: { type: 'es6' },
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
  await fs.writeFile(outputPath, result.code, 'utf8')
  return outputPath
}

async function collectBuildTreeHashParts(currentPath, relativePath = '.') {
  const entries = await fs.readdir(currentPath, { withFileTypes: true })
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
      `${nextRelativePath}\n${createHash('sha256').update(await fs.readFile(fullPath)).digest('hex')}`
    )
  }

  return parts
}

async function readOptionalHash(filePath) {
  try {
    return createHash('sha256').update(await fs.readFile(filePath)).digest('hex')
  } catch {
    return null
  }
}

async function main() {
  const outputs = []

  for (const file of files) {
    outputs.push(await transpile(file))
  }

  const manifestPath = path.join(buildDir, 'public', 'assets', '.vite', 'manifest.json')
  const buildPackageJsonPath = path.join(buildDir, 'package.json')
  const buildStampPath = path.join(buildDir, '.roachnet-build-stamp.json')

  const buildStamp = {
    generatedAt: new Date().toISOString(),
    dependencyHash: createHash('sha256')
      .update(await fs.readFile(path.join(adminDir, 'package-lock.json')))
      .digest('hex'),
    serverEntrypointHash: createHash('sha256')
      .update(await fs.readFile(path.join(buildDir, 'bin', 'server.js')))
      .digest('hex'),
    workerEntrypointHash: createHash('sha256')
      .update(await fs.readFile(path.join(buildDir, 'bin', 'worker.js')))
      .digest('hex'),
    packageJsonHash: createHash('sha256')
      .update(await fs.readFile(buildPackageJsonPath))
      .digest('hex'),
    assetManifestHash: await readOptionalHash(manifestPath),
    treeHash: createHash('sha256')
      .update((await collectBuildTreeHashParts(buildDir)).join('\n---\n'))
      .digest('hex'),
  }

  await fs.writeFile(buildStampPath, JSON.stringify(buildStamp, null, 2) + '\n', 'utf8')
  console.log(
    JSON.stringify(
      {
        outputs,
        buildStampPath,
        treeHash: buildStamp.treeHash,
      },
      null,
      2
    )
  )
}

main().catch((error) => {
  console.error(error instanceof Error ? error.stack ?? error.message : error)
  process.exit(1)
})
