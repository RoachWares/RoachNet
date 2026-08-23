#!/usr/bin/env node

import { readFileSync } from 'node:fs'
import process from 'node:process'

import { verifyGoLiveAttestationBundle } from './go-live-attestation.mjs'

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

function readBundle(bundlePath) {
  const text = readFileSync(bundlePath, 'utf8').trim()
  try {
    const parsed = JSON.parse(text)
    if (Array.isArray(parsed)) {
      if (parsed.length !== 1) throw new Error('Expected exactly one GO-LIVE attestation bundle.')
      return parsed[0]
    }
    return parsed
  } catch (error) {
    const lines = text.split(/\r?\n/).filter(Boolean)
    if (lines.length !== 1) throw error
    return JSON.parse(lines[0])
  }
}

try {
  const args = parseArgs(process.argv.slice(2))
  for (const name of ['bundle', 'predicate', 'subjects']) {
    if (!args[name]) throw new Error(`Missing --${name}`)
  }
  const bundle = readBundle(args.bundle)
  const predicate = JSON.parse(readFileSync(args.predicate, 'utf8'))
  const subjects = JSON.parse(readFileSync(args.subjects, 'utf8')).map((subject) => ({
    name: subject.name,
    digest: subject.digest,
  }))
  verifyGoLiveAttestationBundle(bundle, { predicate, subjects })
  console.log('Verified GO-LIVE DSSE predicate and exact subject set.')
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
