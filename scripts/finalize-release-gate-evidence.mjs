#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import process from 'node:process'

import {
  finalizeReleaseGateEvidence,
  releaseGateBindings,
} from './release-gate-evidence.mjs'

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
  for (const name of ['results', 'provenance', 'snapshot', 'output']) {
    if (!args[name]) throw new Error(`Missing --${name}`)
  }
  const results = JSON.parse(readFileSync(args.results, 'utf8'))
  const provenance = JSON.parse(readFileSync(args.provenance, 'utf8'))
  const snapshotText = readFileSync(args.snapshot, 'utf8')
  const snapshot = JSON.parse(snapshotText)
  const snapshotSha256 = createHash('sha256').update(snapshotText).digest('hex')
  const bindings = releaseGateBindings({ provenance, snapshot, snapshotSha256 })
  const evidence = finalizeReleaseGateEvidence(results, bindings)
  writeFileSync(args.output, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8')
  console.log(`Finalized ${evidence.gates.length} candidate-bound GO-LIVE gate records.`)
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
