#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import { buildGoLivePredicate, canonicalJson } from './go-live-attestation.mjs'
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

const sha256 = (value) => createHash('sha256').update(value).digest('hex')

try {
  const args = parseArgs(process.argv.slice(2))
  const required = [
    'decision', 'repository', 'evidence', 'provenance', 'snapshot', 'body', 'asset-root',
    'promotion-run-id', 'promotion-run-attempt', 'triggering-actor', 'issued-at',
    'predicate-out', 'subjects-dir', 'subjects-manifest-out', 'checksums-out',
  ]
  for (const name of required) if (!args[name]) throw new Error(`Missing --${name}`)

  const evidenceText = readFileSync(args.evidence, 'utf8')
  const evidence = JSON.parse(evidenceText)
  const provenance = JSON.parse(readFileSync(args.provenance, 'utf8'))
  const snapshotText = readFileSync(args.snapshot, 'utf8')
  const snapshot = JSON.parse(snapshotText)
  const body = readFileSync(args.body)
  const snapshotSha256 = sha256(snapshotText)
  const bindings = releaseGateBindings({ provenance, snapshot, snapshotSha256 })
  validateReleaseGateEvidence(evidence, bindings)
  if (sha256(body) !== provenance.renderedReleaseBody.sha256) throw new Error('Stable release body digest does not match provenance.')

  const predicate = buildGoLivePredicate({
    decision: args.decision,
    repository: args.repository,
    candidateSha: provenance.candidateSha,
    tag: provenance.tag,
    stageWorkflowPath: provenance.workflow.path,
    stageRunId: provenance.workflow.runId,
    stageRunAttempt: provenance.workflow.runAttempt,
    promotionWorkflowPath: '.github/workflows/release.yml',
    promotionRunId: Number(args['promotion-run-id']),
    promotionRunAttempt: Number(args['promotion-run-attempt']),
    releaseId: snapshot.releaseId,
    snapshotSha256,
    provenanceSha256: snapshot.provenanceSha256,
    releaseNotesSha256: provenance.releaseNotes.sha256,
    renderedReleaseBodySha256: provenance.renderedReleaseBody.sha256,
    gateEvidenceSha256: sha256(evidenceText),
    assets: snapshot.assets,
    triggeringActor: args['triggering-actor'],
    protectedEnvironment: 'roachnet-release-production',
    issuedAt: args['issued-at'],
  })

  mkdirSync(args['subjects-dir'], { recursive: true })
  const sources = [
    ...snapshot.assets.map((asset) => ({ name: asset.name, source: path.join(args['asset-root'], asset.name), sha256: asset.sha256 })),
    { name: 'stable-release-body.md', source: args.body, sha256: provenance.renderedReleaseBody.sha256 },
    { name: 'staged-release-snapshot.json', source: args.snapshot, sha256: snapshotSha256 },
    { name: 'release-gate-evidence.json', source: args.evidence, sha256: sha256(evidenceText) },
  ].sort((left, right) => left.name.localeCompare(right.name))
  if (new Set(sources.map((subject) => subject.name)).size !== sources.length) throw new Error('GO-LIVE attestation subjects contain duplicate names.')

  const subjects = []
  for (const subject of sources) {
    const contents = readFileSync(subject.source)
    const digest = sha256(contents)
    if (digest !== subject.sha256) throw new Error(`GO-LIVE attestation subject drift: ${subject.name}`)
    const target = path.join(args['subjects-dir'], subject.name)
    copyFileSync(subject.source, target)
    subjects.push({ name: subject.name, path: target, digest: { sha256: digest } })
  }

  writeFileSync(args['predicate-out'], `${canonicalJson(predicate)}\n`, 'utf8')
  writeFileSync(args['subjects-manifest-out'], `${JSON.stringify(subjects, null, 2)}\n`, 'utf8')
  writeFileSync(args['checksums-out'], `${subjects.map((subject) => `${subject.digest.sha256}  ${subject.name}`).join('\n')}\n`, 'utf8')
  console.log(`Prepared canonical GO-LIVE predicate and ${subjects.length} exact subjects.`)
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
