#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { createReadStream, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'

function parseArgs(argv) {
  const values = {}
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!key?.startsWith('--') || !value) throw new Error(`Invalid argument near ${key || '<end>'}`)
    values[key.slice(2)] = value
  }
  return values
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

function walkFiles(rootPath) {
  const files = []
  function walk(currentPath) {
    for (const entry of readdirSync(currentPath, { withFileTypes: true })) {
      const entryPath = path.join(currentPath, entry.name)
      if (entry.isDirectory()) walk(entryPath)
      else if (entry.isFile()) files.push(entryPath)
    }
  }
  walk(rootPath)
  return files.sort()
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, 'utf8'))
}

function modelComponents(roots) {
  const components = []
  for (const root of roots) {
    for (const manifestPath of walkFiles(root).filter((filePath) => filePath.endsWith('RoachSpeechPack.json'))) {
      const manifest = readJson(manifestPath)
      components.push({
        name: manifest.packID || path.basename(path.dirname(manifestPath)),
        version: manifest.version || 'unknown',
        kind: 'model',
        license: manifest.license || manifest.provenance?.license || 'NOASSERTION',
        source: manifest.provenance?.repository || manifest.provenance?.upstreamProject || 'NOASSERTION',
      })
    }
  }
  return components
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const required = ['dmg', 'setup-app', 'desktop-app', 'candidate-sha', 'tag', 'out']
  for (const key of required) {
    if (!args[key]) throw new Error(`Missing --${key}`)
  }
  for (const key of ['dmg', 'setup-app', 'desktop-app']) {
    if (!existsSync(args[key])) throw new Error(`Missing ${key} path: ${args[key]}`)
  }

  const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')
  const packageManifest = readJson(path.join(repoRoot, 'package.json'))
  const runtimePins = readJson(path.join(repoRoot, 'docs', 'release-gates', 'runtime-freshness.json'))
  const roots = [args['setup-app'], args['desktop-app']]
  const inventory = []

  for (const root of roots) {
    for (const filePath of walkFiles(root)) {
      const stats = statSync(filePath)
      inventory.push({
        path: `${path.basename(root)}/${path.relative(root, filePath).split(path.sep).join('/')}`,
        bytes: stats.size,
        sha256: await sha256File(filePath),
        executable: (stats.mode & 0o111) !== 0,
      })
    }
  }

  const components = [
    {
      name: 'RoachNet',
      version: packageManifest.version,
      kind: 'application',
      license: packageManifest.license,
      source: `git+https://github.com/RoachWares/RoachNet.git#${args['candidate-sha']}`,
    },
    {
      name: 'Node.js',
      version: runtimePins.node.bundledVersion,
      kind: 'runtime',
      license: runtimePins.node.license,
      source: runtimePins.node.artifacts.darwinArm64.url,
      sourceSha256: runtimePins.node.artifacts.darwinArm64.sha256,
    },
    {
      name: 'Ollama',
      version: runtimePins.ollama.bundledVersion,
      kind: 'runtime',
      license: runtimePins.ollama.license,
      source: runtimePins.ollama.artifact.url,
      sourceSha256: runtimePins.ollama.artifact.sha256,
    },
    {
      name: 'OpenClaw',
      version: 'not-bundled',
      kind: 'deferred-optional-runtime',
      license: 'N/A',
      source: runtimePins.openclaw.source,
    },
    ...modelComponents(roots),
  ]

  const dmgSha256 = await sha256File(args.dmg)
  const documentNamespace = `https://roachnet.org/sbom/${args.tag}/${args['candidate-sha']}/${dmgSha256}`
  const sbom = {
    spdxVersion: 'SPDX-2.3',
    dataLicense: 'CC0-1.0',
    SPDXID: 'SPDXRef-DOCUMENT',
    name: `RoachNet ${packageManifest.version}`,
    documentNamespace,
    creationInfo: {
      created: new Date().toISOString(),
      creators: ['Tool: RoachNet generate-release-supply-chain.mjs'],
    },
    packages: components.map((component, index) => ({
      SPDXID: `SPDXRef-Package-${index + 1}`,
      name: component.name,
      versionInfo: component.version,
      downloadLocation: component.source,
      licenseConcluded: component.license,
      licenseDeclared: component.license,
      checksums: component.sourceSha256
        ? [{ algorithm: 'SHA256', checksumValue: component.sourceSha256 }]
        : [],
      primaryPackagePurpose: component.kind === 'application' ? 'APPLICATION' : 'RUNTIME',
    })),
  }

  const releaseInventory = {
    schema: 'org.roachnet.release-supply-chain.v1',
    candidateSha: args['candidate-sha'],
    tag: args.tag,
    version: packageManifest.version,
    buildNumber: packageManifest.buildNumber,
    dmg: {
      filename: path.basename(args.dmg),
      bytes: statSync(args.dmg).size,
      sha256: dmgSha256,
    },
    components,
    files: inventory,
  }

  mkdirSync(args.out, { recursive: true })
  writeFileSync(path.join(args.out, 'sbom.spdx.json'), `${JSON.stringify(sbom, null, 2)}\n`)
  writeFileSync(path.join(args.out, 'binary-license-inventory.json'), `${JSON.stringify(releaseInventory, null, 2)}\n`)
  console.log(`Generated release supply-chain records for ${inventory.length} mounted-artifact files.`)
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
