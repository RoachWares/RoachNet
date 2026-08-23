#!/usr/bin/env node

import { sortedReleaseAssets } from './release-gate-evidence.mjs'

const SHA256 = /^[a-f0-9]{64}$/
const COMMIT_SHA = /^[a-f0-9]{40}$/
export const GO_LIVE_PREDICATE_TYPE = 'https://github.com/RoachWares/RoachNet/attestations/go-live/v1'

function requireValue(condition, message) {
  if (!condition) throw new Error(message)
}

function requireSha256(value, label) {
  requireValue(SHA256.test(String(value || '')), `${label} must be a lowercase SHA-256 digest.`)
}

function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize)
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, normalize(value[key])])
    )
  }
  return value
}

export function canonicalJson(value) {
  return JSON.stringify(normalize(value))
}

export function buildGoLivePredicate(input) {
  requireValue(input?.decision === 'GO-LIVE', 'GO-LIVE predicate decision must be the exact literal GO-LIVE.')
  requireValue(input.repository === 'RoachWares/RoachNet', 'GO-LIVE predicate repository is invalid.')
  requireValue(COMMIT_SHA.test(String(input.candidateSha || '')), 'GO-LIVE predicate candidate SHA is invalid.')
  requireValue(/^v\d+\.\d+\.\d+$/.test(String(input.tag || '')), 'GO-LIVE predicate tag is invalid.')
  for (const [field, label] of [
    ['snapshotSha256', 'Snapshot'],
    ['provenanceSha256', 'Provenance'],
    ['releaseNotesSha256', 'Tracked release notes'],
    ['renderedReleaseBodySha256', 'Rendered release body'],
    ['gateEvidenceSha256', 'Release gate evidence'],
  ]) requireSha256(input[field], label)
  for (const [field, label] of [
    ['stageRunId', 'Stage run ID'],
    ['stageRunAttempt', 'Stage run attempt'],
    ['promotionRunId', 'Promotion run ID'],
    ['promotionRunAttempt', 'Promotion run attempt'],
    ['releaseId', 'Release ID'],
  ]) requireValue(Number.isSafeInteger(input[field]) && input[field] > 0, `${label} is invalid.`)
  requireValue(input.stageWorkflowPath === '.github/workflows/native-packages.yml', 'Stage workflow path is invalid.')
  requireValue(input.promotionWorkflowPath === '.github/workflows/release.yml', 'Promotion workflow path is invalid.')
  requireValue(typeof input.triggeringActor === 'string' && input.triggeringActor.length > 0, 'Triggering actor is missing.')
  requireValue(input.protectedEnvironment === 'roachnet-release-production', 'Protected environment is invalid.')
  requireValue(!Number.isNaN(Date.parse(input.issuedAt)), 'GO-LIVE issuance time is invalid.')

  return {
    schema: 'org.roachnet.go-live.v1',
    decision: 'GO-LIVE',
    repository: input.repository,
    candidateSha: input.candidateSha,
    tag: input.tag,
    stageWorkflow: {
      path: input.stageWorkflowPath,
      runId: input.stageRunId,
      runAttempt: input.stageRunAttempt,
    },
    promotionWorkflow: {
      path: input.promotionWorkflowPath,
      runId: input.promotionRunId,
      runAttempt: input.promotionRunAttempt,
    },
    releaseId: input.releaseId,
    snapshotSha256: input.snapshotSha256,
    provenanceSha256: input.provenanceSha256,
    releaseNotesSha256: input.releaseNotesSha256,
    renderedReleaseBodySha256: input.renderedReleaseBodySha256,
    gateEvidenceSha256: input.gateEvidenceSha256,
    assets: sortedReleaseAssets(input.assets),
    triggeringActor: input.triggeringActor,
    protectedEnvironment: input.protectedEnvironment,
    issuedAt: new Date(input.issuedAt).toISOString(),
  }
}

function sortedSubjects(subjects) {
  requireValue(Array.isArray(subjects) && subjects.length > 0, 'Attestation subject set is empty.')
  const normalized = subjects.map((subject, index) => {
    requireValue(typeof subject?.name === 'string' && subject.name.length > 0, `Attestation subject ${index + 1} has no name.`)
    requireSha256(subject.digest?.sha256, `Attestation subject ${subject.name}`)
    return { name: subject.name, digest: { sha256: subject.digest.sha256 } }
  })
  requireValue(new Set(normalized.map((subject) => subject.name)).size === normalized.length, 'Attestation subjects contain duplicate names.')
  return normalized.sort((left, right) => left.name.localeCompare(right.name))
}

export function verifyGoLiveAttestationBundle(bundle, expected) {
  const envelope = bundle?.dsseEnvelope || bundle?.content?.dsseEnvelope
  requireValue(envelope && typeof envelope.payload === 'string', 'Attestation bundle does not contain a DSSE payload.')
  requireValue(Array.isArray(envelope.signatures) && envelope.signatures.length > 0, 'Attestation bundle does not contain a signature.')
  let statement
  try {
    statement = JSON.parse(Buffer.from(envelope.payload, 'base64').toString('utf8'))
  } catch {
    throw new Error('Attestation bundle contains an invalid DSSE statement.')
  }
  requireValue(statement._type === 'https://in-toto.io/Statement/v1', 'Attestation statement type is invalid.')
  requireValue(statement.predicateType === GO_LIVE_PREDICATE_TYPE, 'Attestation predicate type is invalid.')
  requireValue(
    canonicalJson(statement.predicate) === canonicalJson(expected.predicate),
    'Attestation predicate does not match the authorized GO-LIVE predicate.'
  )
  requireValue(
    canonicalJson(sortedSubjects(statement.subject)) === canonicalJson(sortedSubjects(expected.subjects)),
    'Attestation subject set does not match the authorized release subjects.'
  )
  return true
}
