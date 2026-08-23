#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs'
import process from 'node:process'

import {
  createStagedReleaseSnapshot,
  verifyStagedReleaseSnapshot,
} from './release-provenance.mjs'

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
  for (const name of ['mode', 'release-json', 'provenance', 'notes', 'snapshot']) {
    if (!args[name]) throw new Error(`Missing --${name}`)
  }
  if (!['create', 'verify'].includes(args.mode)) throw new Error('--mode must be create or verify')

  const release = JSON.parse(readFileSync(args['release-json'], 'utf8'))
  const provenanceText = readFileSync(args.provenance, 'utf8')
  const provenance = JSON.parse(provenanceText)
  const notes = readFileSync(args.notes, 'utf8')

  if (args.mode === 'create') {
    const snapshot = createStagedReleaseSnapshot(release, provenance, notes, provenanceText)
    writeFileSync(args.snapshot, `${JSON.stringify(snapshot, null, 2)}\n`, 'utf8')
    console.log(`Created staged release snapshot for release ${snapshot.releaseId}.`)
  } else {
    const snapshot = JSON.parse(readFileSync(args.snapshot, 'utf8'))
    verifyStagedReleaseSnapshot(release, snapshot, provenance, notes, provenanceText)
    console.log(`Verified staged release snapshot for release ${snapshot.releaseId}.`)
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
