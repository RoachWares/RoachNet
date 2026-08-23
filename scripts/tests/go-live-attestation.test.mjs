import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import test from 'node:test'

import {
  REQUIRED_GO_LIVE_GATE_IDS_V1,
  finalizeReleaseGateEvidence,
  validateReleaseGateEvidence,
  validateReleaseGateResults,
} from '../release-gate-evidence.mjs'
import {
  buildGoLivePredicate,
  canonicalJson,
  verifyGoLiveAttestationBundle,
} from '../go-live-attestation.mjs'

const candidateSha = 'a'.repeat(40)
const artifactSha256 = 'b'.repeat(64)
const snapshotSha256 = 'c'.repeat(64)
const provenanceSha256 = 'd'.repeat(64)
const notesSha256 = 'e'.repeat(64)
const bodySha256 = 'f'.repeat(64)
const gateEvidenceSha256 = '1'.repeat(64)
const evidenceDigest = '2'.repeat(64)

function assets() {
  return [
    {
      id: 101,
      name: 'RoachNet-Setup-macOS.dmg',
      bytes: 468166812,
      sha256: artifactSha256,
      url: 'https://github.com/RoachWares/RoachNet/releases/download/v1.0.6/RoachNet-Setup-macOS.dmg',
    },
    {
      id: 102,
      name: 'release-provenance.json',
      bytes: 4096,
      sha256: provenanceSha256,
      url: 'https://github.com/RoachWares/RoachNet/releases/download/v1.0.6/release-provenance.json',
    },
  ]
}

function gateEvidence() {
  return {
    schema: 'org.roachnet.release-gate-evidence.v1',
    policy: 'org.roachnet.go-live-gates.v1',
    repository: 'RoachWares/RoachNet',
    candidateSha,
    tag: 'v1.0.6',
    artifactSha256,
    stageWorkflow: {
      path: '.github/workflows/native-packages.yml',
      runId: 12345,
      runAttempt: 2,
    },
    releaseId: 9876,
    snapshotSha256,
    provenanceSha256,
    releaseNotesSha256: notesSha256,
    renderedReleaseBodySha256: bodySha256,
    assets: assets().sort((left, right) => left.name.localeCompare(right.name)),
    gates: REQUIRED_GO_LIVE_GATE_IDS_V1.map((gateId, index) => ({
      gateId,
      result: 'PASS',
      candidateSha,
      artifactSha256,
      runId: 20000 + index,
      runAttempt: 1,
      checkName: `verified-${gateId.toLowerCase()}`,
      evidenceUri: `https://github.com/RoachWares/RoachNet/actions/runs/${20000 + index}`,
      evidenceSha256: evidenceDigest,
    })),
  }
}

function bindings() {
  return {
    repository: 'RoachWares/RoachNet',
    candidateSha,
    tag: 'v1.0.6',
    artifactSha256,
    stageWorkflowPath: '.github/workflows/native-packages.yml',
    stageRunId: 12345,
    stageRunAttempt: 2,
    releaseId: 9876,
    snapshotSha256,
    provenanceSha256,
    releaseNotesSha256: notesSha256,
    renderedReleaseBodySha256: bodySha256,
    assets: assets(),
  }
}

test('release gate evidence requires the exact versioned GO-LIVE gate set and immutable bindings', () => {
  assert.doesNotThrow(() => validateReleaseGateEvidence(gateEvidence(), bindings()))

  const results = {
    schema: 'org.roachnet.release-gate-results.v1',
    policy: 'org.roachnet.go-live-gates.v1',
    repository: 'RoachWares/RoachNet',
    candidateSha,
    artifactSha256,
    gates: gateEvidence().gates,
  }
  assert.doesNotThrow(() => validateReleaseGateResults(results, {
    repository: 'RoachWares/RoachNet',
    candidateSha,
    artifactSha256,
  }))
  assert.deepEqual(finalizeReleaseGateEvidence(results, bindings()), gateEvidence())

  const missing = gateEvidence()
  missing.gates.pop()
  assert.throws(() => validateReleaseGateEvidence(missing, bindings()), /gate set/i)

  const duplicate = gateEvidence()
  duplicate.gates[1] = { ...duplicate.gates[0] }
  assert.throws(() => validateReleaseGateEvidence(duplicate, bindings()), /duplicate|gate set/i)

  const failed = gateEvidence()
  failed.gates[0].result = 'NOT RUN'
  assert.throws(() => validateReleaseGateEvidence(failed, bindings()), /must be PASS/i)

  const stale = gateEvidence()
  stale.gates[0].artifactSha256 = '0'.repeat(64)
  assert.throws(() => validateReleaseGateEvidence(stale, bindings()), /artifact/i)
})

test('GO-LIVE predicate canonically binds decision, runs, release, evidence, and exact sorted assets', () => {
  const predicate = buildGoLivePredicate({
    decision: 'GO-LIVE',
    repository: 'RoachWares/RoachNet',
    candidateSha,
    tag: 'v1.0.6',
    stageWorkflowPath: '.github/workflows/native-packages.yml',
    stageRunId: 12345,
    stageRunAttempt: 2,
    promotionWorkflowPath: '.github/workflows/release.yml',
    promotionRunId: 54321,
    promotionRunAttempt: 1,
    releaseId: 9876,
    snapshotSha256,
    provenanceSha256,
    releaseNotesSha256: notesSha256,
    renderedReleaseBodySha256: bodySha256,
    gateEvidenceSha256,
    assets: assets().reverse(),
    triggeringActor: 'trusted-maintainer',
    protectedEnvironment: 'roachnet-release-production',
    issuedAt: '2026-08-23T12:00:00.000Z',
  })

  assert.equal(predicate.schema, 'org.roachnet.go-live.v1')
  assert.equal(predicate.decision, 'GO-LIVE')
  assert.deepEqual(predicate.assets.map((asset) => asset.name), [
    'release-provenance.json',
    'RoachNet-Setup-macOS.dmg',
  ].sort((left, right) => left.localeCompare(right)))
  assert.equal(`${canonicalJson(predicate)}\n`, `${canonicalJson(JSON.parse(canonicalJson(predicate)))}\n`)
  assert.throws(() => buildGoLivePredicate({ ...predicate, decision: 'GO' }), /GO-LIVE/)
})

test('attestation bundle verification rejects predicate or subject drift', () => {
  const predicate = buildGoLivePredicate({
    decision: 'GO-LIVE',
    repository: 'RoachWares/RoachNet',
    candidateSha,
    tag: 'v1.0.6',
    stageWorkflowPath: '.github/workflows/native-packages.yml',
    stageRunId: 12345,
    stageRunAttempt: 2,
    promotionWorkflowPath: '.github/workflows/release.yml',
    promotionRunId: 54321,
    promotionRunAttempt: 1,
    releaseId: 9876,
    snapshotSha256,
    provenanceSha256,
    releaseNotesSha256: notesSha256,
    renderedReleaseBodySha256: bodySha256,
    gateEvidenceSha256,
    assets: assets(),
    triggeringActor: 'trusted-maintainer',
    protectedEnvironment: 'roachnet-release-production',
    issuedAt: '2026-08-23T12:00:00.000Z',
  })
  const subjects = [
    { name: 'RoachNet-Setup-macOS.dmg', digest: { sha256: artifactSha256 } },
    { name: 'stable-release-body.md', digest: { sha256: bodySha256 } },
  ]
  const statement = {
    _type: 'https://in-toto.io/Statement/v1',
    subject: subjects,
    predicateType: 'https://github.com/RoachWares/RoachNet/attestations/go-live/v1',
    predicate,
  }
  const bundle = {
    dsseEnvelope: {
      payloadType: 'application/vnd.in-toto+json',
      payload: Buffer.from(canonicalJson(statement)).toString('base64'),
      signatures: [{ sig: 'fixture-signature' }],
    },
  }

  assert.doesNotThrow(() => verifyGoLiveAttestationBundle(bundle, { predicate, subjects }))
  assert.throws(
    () => verifyGoLiveAttestationBundle(bundle, {
      predicate: { ...predicate, releaseId: 9877 },
      subjects,
    }),
    /predicate/i
  )
  assert.throws(
    () => verifyGoLiveAttestationBundle(bundle, {
      predicate,
      subjects: [{ name: 'RoachNet-Setup-macOS.dmg', digest: { sha256: '0'.repeat(64) } }],
    }),
    /subject/i
  )
})
