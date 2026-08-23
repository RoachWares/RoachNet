#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { readFileSync, statSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import {
  REQUIRED_GO_LIVE_GATE_IDS_V1,
  validateReleaseGateResults,
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

function sha256File(filePath) {
  return createHash('sha256').update(readFileSync(filePath)).digest('hex')
}

function resolveEvidenceFile(root, relativePath) {
  if (typeof relativePath !== 'string' || relativePath.length === 0 || path.isAbsolute(relativePath)) {
    throw new Error('Release-gate evidence path must be a non-empty relative path.')
  }
  const resolvedRoot = path.resolve(root)
  const resolvedFile = path.resolve(resolvedRoot, relativePath)
  if (!resolvedFile.startsWith(`${resolvedRoot}${path.sep}`)) {
    throw new Error('Release-gate evidence path escapes the approved evidence root.')
  }
  if (!statSync(resolvedFile).isFile()) throw new Error(`Release-gate evidence is not a file: ${relativePath}`)
  return resolvedFile
}

try {
  const args = parseArgs(process.argv.slice(2))
  for (const name of ['records', 'evidence-root', 'repository', 'candidate-sha', 'artifact-sha256', 'run-id', 'run-attempt', 'output']) {
    if (!args[name]) throw new Error(`Missing --${name}`)
  }
  const records = JSON.parse(readFileSync(args.records, 'utf8'))
  if (records?.schema !== 'org.roachnet.release-gate-records.v1' || records.policy !== 'org.roachnet.go-live-gates.v1') {
    throw new Error('Unknown release-gate records schema or policy.')
  }
  if (!Array.isArray(records.gates)) throw new Error('Release-gate records do not contain a gate matrix.')
  const gateIds = records.gates.map((gate) => gate?.gateId)
  if (new Set(gateIds).size !== gateIds.length || JSON.stringify([...gateIds].sort()) !== JSON.stringify([...REQUIRED_GO_LIVE_GATE_IDS_V1].sort())) {
    throw new Error('Release-gate records must contain the exact versioned GO-LIVE gate set once.')
  }
  const runId = Number(args['run-id'])
  const runAttempt = Number(args['run-attempt'])
  if (!Number.isSafeInteger(runId) || runId <= 0 || !Number.isSafeInteger(runAttempt) || runAttempt <= 0) {
    throw new Error('Release-gate run ID or attempt is invalid.')
  }

  const results = {
    schema: 'org.roachnet.release-gate-results.v1',
    policy: records.policy,
    repository: args.repository,
    candidateSha: args['candidate-sha'],
    artifactSha256: args['artifact-sha256'],
    gates: records.gates.map((gate) => {
      if (gate.result !== 'PASS') throw new Error(`Release-gate record ${gate.gateId} is not PASS.`)
      if (typeof gate.checkName !== 'string' || gate.checkName.trim().length === 0 || /[\r\n\t]/.test(gate.checkName)) {
        throw new Error(`Release-gate record ${gate.gateId} has an invalid check name.`)
      }
      const evidenceFile = resolveEvidenceFile(args['evidence-root'], gate.evidencePath)
      return {
        gateId: gate.gateId,
        result: 'PASS',
        candidateSha: args['candidate-sha'],
        artifactSha256: args['artifact-sha256'],
        runId,
        runAttempt,
        checkName: gate.checkName,
        evidencePath: gate.evidencePath,
        evidenceUri: `https://github.com/${args.repository}/actions/runs/${runId}`,
        evidenceSha256: sha256File(evidenceFile),
      }
    }),
  }
  validateReleaseGateResults(results, {
    repository: args.repository,
    candidateSha: args['candidate-sha'],
    artifactSha256: args['artifact-sha256'],
  })
  writeFileSync(args.output, `${JSON.stringify(results, null, 2)}\n`, 'utf8')
  console.log(`Finalized ${results.gates.length} independently supplied candidate-bound release-gate results.`)
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
