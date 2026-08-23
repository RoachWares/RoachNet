#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import { validateReleaseGateResults } from './release-gate-evidence.mjs'

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

function resolveEvidenceFile(root, relativePath) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || path.isAbsolute(relativePath)) {
    throw new Error('Release-gate result has an invalid evidence path.')
  }
  const resolvedRoot = path.resolve(root)
  const resolvedFile = path.resolve(resolvedRoot, relativePath)
  if (!resolvedFile.startsWith(`${resolvedRoot}${path.sep}`) || !statSync(resolvedFile).isFile()) {
    throw new Error(`Release-gate evidence is unavailable: ${relativePath}`)
  }
  return resolvedFile
}

try {
  const args = parseArgs(process.argv.slice(2))
  for (const name of ['results', 'evidence-root', 'repository', 'candidate-sha', 'artifact-sha256']) {
    if (!args[name]) throw new Error(`Missing --${name}`)
  }
  const results = JSON.parse(readFileSync(args.results, 'utf8'))
  validateReleaseGateResults(results, {
    repository: args.repository,
    candidateSha: args['candidate-sha'],
    artifactSha256: args['artifact-sha256'],
  })
  for (const gate of results.gates) {
    const evidenceFile = resolveEvidenceFile(args['evidence-root'], gate.evidencePath)
    const actual = createHash('sha256').update(readFileSync(evidenceFile)).digest('hex')
    if (actual !== gate.evidenceSha256) throw new Error(`Release-gate evidence digest mismatch: ${gate.gateId}`)
  }
  console.log(`Verified ${results.gates.length} exact release-gate evidence files and digests.`)
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
