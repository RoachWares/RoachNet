#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import process from 'node:process'

import {
  releaseGateBindings,
  validateReleaseGateEvidence,
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
  for (const name of ['evidence', 'provenance', 'snapshot']) {
    if (!args[name]) throw new Error(`Missing --${name}`)
  }
  const evidence = JSON.parse(readFileSync(args.evidence, 'utf8'))
  const provenance = JSON.parse(readFileSync(args.provenance, 'utf8'))
  const snapshotText = readFileSync(args.snapshot, 'utf8')
  const snapshot = JSON.parse(snapshotText)
  const snapshotSha256 = createHash('sha256').update(snapshotText).digest('hex')
  validateReleaseGateEvidence(
    evidence,
    releaseGateBindings({ provenance, snapshot, snapshotSha256 })
  )
  console.log(`Verified ${evidence.gates.length} exact candidate-bound GO-LIVE gate records.`)
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
