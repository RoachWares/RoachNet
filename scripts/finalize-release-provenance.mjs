#!/usr/bin/env node

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import { createReleaseProvenance, verifyRenderedReleaseBody } from './release-provenance.mjs'

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

function requireArgs(values, names) {
  for (const name of names) {
    if (!values[name]) throw new Error(`Missing --${name}`)
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  requireArgs(args, [
    'dist',
    'notes',
    'signing-evidence',
    'candidate-sha',
    'tag',
    'repository',
    'workflow-run-id',
    'workflow-run-attempt',
    'workflow-ref',
    'provenance-out',
    'body-out',
  ])

  const packageManifest = JSON.parse(readFileSync('package.json', 'utf8'))
  const releaseNotes = readFileSync(args.notes, 'utf8')
  const signingEvidence = JSON.parse(readFileSync(args['signing-evidence'], 'utf8'))
  const bound = createReleaseProvenance({
    distPath: args.dist,
    releaseNotes,
    releaseNotesPath: args.notes,
    candidateSha: args['candidate-sha'],
    tag: args.tag,
    version: packageManifest.version,
    buildNumber: packageManifest.buildNumber,
    repository: args.repository,
    workflowRunId: Number(args['workflow-run-id']),
    workflowRunAttempt: Number(args['workflow-run-attempt']),
    workflowRef: args['workflow-ref'],
    signingEvidence,
  })
  verifyRenderedReleaseBody(bound.body, releaseNotes, bound.provenance)

  mkdirSync(path.dirname(args['provenance-out']), { recursive: true })
  mkdirSync(path.dirname(args['body-out']), { recursive: true })
  writeFileSync(args['provenance-out'], `${JSON.stringify(bound.provenance, null, 2)}\n`, 'utf8')
  writeFileSync(args['body-out'], bound.body, 'utf8')
  console.log(`Finalized release provenance and stable body ${bound.provenance.renderedReleaseBody.sha256}.`)
}

try {
  main()
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
