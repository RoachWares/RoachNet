#!/usr/bin/env node

import { readFileSync } from 'node:fs'
import process from 'node:process'

import { verifyPublishedRelease } from './release-provenance.mjs'

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
  for (const name of ['release-json', 'snapshot', 'provenance', 'body', 'version']) {
    if (!args[name]) throw new Error(`Missing --${name}`)
  }
  const release = JSON.parse(readFileSync(args['release-json'], 'utf8'))
  const snapshot = JSON.parse(readFileSync(args.snapshot, 'utf8'))
  const provenance = JSON.parse(readFileSync(args.provenance, 'utf8'))
  const body = readFileSync(args.body, 'utf8')
  verifyPublishedRelease(release, snapshot, provenance, body, args.version)
  console.log(`Verified published release ${release.id} against exact staged identity.`)
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
