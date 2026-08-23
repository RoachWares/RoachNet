import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { REQUIRED_GO_LIVE_GATE_IDS_V1 } from '../release-gate-evidence.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const candidateSha = 'a'.repeat(40)
const artifactSha256 = 'b'.repeat(64)
const sha256 = (value) => createHash('sha256').update(value).digest('hex')

function run(script, args) {
  return execFileSync(process.execPath, [path.join(repoRoot, 'scripts', script), ...args], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
}

test('gate result finalizer requires externally supplied evidence and verifier detects drift', () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'roachnet-gate-materials-'))
  try {
    const evidenceRoot = path.join(root, 'evidence')
    mkdirSync(evidenceRoot, { recursive: true })
    const recordsPath = path.join(root, 'records.json')
    const resultsPath = path.join(root, 'results.json')
    const gates = REQUIRED_GO_LIVE_GATE_IDS_V1.map((gateId) => {
      const evidencePath = `${gateId}.json`
      writeFileSync(path.join(evidenceRoot, evidencePath), `${gateId}\n`, { encoding: 'utf8', flag: 'w' })
      return { gateId, result: 'PASS', checkName: `Gate ${gateId}`, evidencePath }
    })
    writeFileSync(recordsPath, `${JSON.stringify({
      schema: 'org.roachnet.release-gate-records.v1',
      policy: 'org.roachnet.go-live-gates.v1',
      gates,
    }, null, 2)}\n`)

    run('finalize-release-gate-results.mjs', [
      '--records', recordsPath,
      '--evidence-root', evidenceRoot,
      '--repository', 'RoachWares/RoachNet',
      '--candidate-sha', candidateSha,
      '--artifact-sha256', artifactSha256,
      '--run-id', '12345',
      '--run-attempt', '1',
      '--output', resultsPath,
    ])
    run('verify-release-gate-materials.mjs', [
      '--results', resultsPath,
      '--evidence-root', evidenceRoot,
      '--repository', 'RoachWares/RoachNet',
      '--candidate-sha', candidateSha,
      '--artifact-sha256', artifactSha256,
    ])

    const firstEvidence = path.join(evidenceRoot, `${REQUIRED_GO_LIVE_GATE_IDS_V1[0]}.json`)
    writeFileSync(firstEvidence, 'tampered\n')
    assert.throws(() => run('verify-release-gate-materials.mjs', [
      '--results', resultsPath,
      '--evidence-root', evidenceRoot,
      '--repository', 'RoachWares/RoachNet',
      '--candidate-sha', candidateSha,
      '--artifact-sha256', artifactSha256,
    ]), /Release-gate evidence digest mismatch/)

    const result = JSON.parse(readFileSync(resultsPath, 'utf8'))
    assert.equal(result.gates[0].evidenceSha256, sha256(`${REQUIRED_GO_LIVE_GATE_IDS_V1[0]}\n`))
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
