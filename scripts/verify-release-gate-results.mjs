#!/usr/bin/env node

import { readFileSync } from 'node:fs'
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

try {
  const args = parseArgs(process.argv.slice(2))
  for (const name of ['results', 'repository', 'candidate-sha', 'artifact-sha256']) {
    if (!args[name]) throw new Error(`Missing --${name}`)
  }
  const results = JSON.parse(readFileSync(args.results, 'utf8'))
  validateReleaseGateResults(results, {
    repository: args.repository,
    candidateSha: args['candidate-sha'],
    artifactSha256: args['artifact-sha256'],
  })
  console.log(`Verified ${results.gates.length} exact GO-LIVE gate results.`)
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
