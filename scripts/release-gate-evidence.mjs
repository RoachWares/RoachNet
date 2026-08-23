#!/usr/bin/env node

import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const SHA256 = /^[a-f0-9]{64}$/
const COMMIT_SHA = /^[a-f0-9]{40}$/
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const goLivePolicy = JSON.parse(readFileSync(path.join(repoRoot, 'docs/release-gates/go-live-gates-v1.json'), 'utf8'))

const policyGateIds = goLivePolicy.requiredGates.map((gate) => gate.id)
if (
  goLivePolicy.schema !== 'org.roachnet.go-live-gate-policy.v1' ||
  goLivePolicy.policy !== 'org.roachnet.go-live-gates.v1' ||
  policyGateIds.length === 0 ||
  new Set(policyGateIds).size !== policyGateIds.length ||
  goLivePolicy.requiredGates.some((gate) => !/^P[01]-\d{2}-[a-z0-9-]+$/.test(gate.id) || !['P0', 'P1'].includes(gate.priority))
) {
  throw new Error('Unknown or invalid authoritative GO-LIVE gate policy.')
}

export const REQUIRED_GO_LIVE_GATE_IDS_V1 = Object.freeze(policyGateIds)

function requireValue(condition, message) {
  if (!condition) throw new Error(message)
}

function requireSha256(value, label) {
  requireValue(SHA256.test(String(value || '')), `${label} must be a lowercase SHA-256 digest.`)
}

function normalizeAsset(asset, label) {
  requireValue(Number.isSafeInteger(asset?.id) && asset.id > 0, `${label} has an invalid asset ID.`)
  requireValue(typeof asset.name === 'string' && asset.name.length > 0, `${label} has an invalid asset name.`)
  requireValue(Number.isSafeInteger(asset.bytes) && asset.bytes > 0, `${label} has an invalid byte size.`)
  requireSha256(asset.sha256, `${label} digest`)
  requireValue(
    typeof asset.url === 'string' && asset.url.startsWith('https://github.com/RoachWares/RoachNet/releases/download/'),
    `${label} has an invalid release URL.`
  )
  return {
    id: asset.id,
    name: asset.name,
    bytes: asset.bytes,
    sha256: asset.sha256,
    url: asset.url,
  }
}

export function sortedReleaseAssets(assets) {
  requireValue(Array.isArray(assets) && assets.length > 0, 'Release asset set is empty.')
  const normalized = assets.map((asset, index) => normalizeAsset(asset, `Release asset ${index + 1}`))
  const names = normalized.map((asset) => asset.name)
  requireValue(new Set(names).size === names.length, 'Release asset set contains duplicate names.')
  return normalized.sort((left, right) => left.name.localeCompare(right.name))
}

function sameValue(actual, expected, label) {
  requireValue(actual === expected, `${label} does not match the staged candidate.`)
}

export function validateReleaseGateResults(results, bindings) {
  requireValue(results?.schema === 'org.roachnet.release-gate-results.v1', 'Unknown release gate results schema.')
  requireValue(results.policy === 'org.roachnet.go-live-gates.v1', 'Unknown release gate results policy.')
  sameValue(results.repository, bindings.repository, 'Gate results repository')
  sameValue(results.candidateSha, bindings.candidateSha, 'Gate results candidate SHA')
  sameValue(results.artifactSha256, bindings.artifactSha256, 'Gate results artifact digest')
  requireValue(Array.isArray(results.gates), 'Release gate results do not contain a gate matrix.')
  const gateIds = results.gates.map((gate) => gate?.gateId)
  requireValue(new Set(gateIds).size === gateIds.length, 'Release gate results contain a duplicate gate ID.')
  requireValue(
    JSON.stringify([...gateIds].sort()) === JSON.stringify([...REQUIRED_GO_LIVE_GATE_IDS_V1].sort()),
    'Release gate results gate set does not exactly match org.roachnet.go-live-gates.v1.'
  )
  for (const gate of results.gates) {
    requireValue(gate.result === 'PASS', `Release gate ${gate.gateId} must be PASS.`)
    sameValue(gate.candidateSha, bindings.candidateSha, `Release gate ${gate.gateId} candidate SHA`)
    sameValue(gate.artifactSha256, bindings.artifactSha256, `Release gate ${gate.gateId} artifact digest`)
    requireValue(Number.isSafeInteger(gate.runId) && gate.runId > 0, `Release gate ${gate.gateId} has an invalid run ID.`)
    requireValue(Number.isSafeInteger(gate.runAttempt) && gate.runAttempt > 0, `Release gate ${gate.gateId} has an invalid run attempt.`)
    requireValue(
      typeof gate.checkName === 'string' && gate.checkName.trim().length > 0 && !/[\r\n\t]/.test(gate.checkName),
      `Release gate ${gate.gateId} has an invalid check name.`
    )
    requireValue(
      gate.evidenceUri === `https://github.com/RoachWares/RoachNet/actions/runs/${gate.runId}` ||
        gate.evidenceUri.startsWith(`https://github.com/RoachWares/RoachNet/actions/runs/${gate.runId}/`),
      `Release gate ${gate.gateId} evidence URI is not bound to its exact run ID.`
    )
    requireSha256(gate.evidenceSha256, `Release gate ${gate.gateId} evidence`)
  }
  return true
}

export function validateReleaseGateEvidence(evidence, bindings) {
  requireValue(evidence?.schema === 'org.roachnet.release-gate-evidence.v1', 'Unknown release gate evidence schema.')
  requireValue(evidence.policy === 'org.roachnet.go-live-gates.v1', 'Unknown release gate policy.')
  sameValue(evidence.repository, bindings.repository, 'Evidence repository')
  requireValue(COMMIT_SHA.test(String(evidence.candidateSha || '')), 'Evidence candidate SHA is invalid.')
  sameValue(evidence.candidateSha, bindings.candidateSha, 'Evidence candidate SHA')
  sameValue(evidence.tag, bindings.tag, 'Evidence tag')
  requireSha256(evidence.artifactSha256, 'Evidence artifact')
  sameValue(evidence.artifactSha256, bindings.artifactSha256, 'Evidence artifact digest')

  const stage = evidence.stageWorkflow || {}
  sameValue(stage.path, bindings.stageWorkflowPath, 'Evidence stage workflow path')
  sameValue(stage.runId, bindings.stageRunId, 'Evidence stage run ID')
  sameValue(stage.runAttempt, bindings.stageRunAttempt, 'Evidence stage run attempt')
  requireValue(Number.isSafeInteger(stage.runId) && stage.runId > 0, 'Evidence stage run ID is invalid.')
  requireValue(Number.isSafeInteger(stage.runAttempt) && stage.runAttempt > 0, 'Evidence stage run attempt is invalid.')

  sameValue(evidence.releaseId, bindings.releaseId, 'Evidence release ID')
  for (const [field, label] of [
    ['snapshotSha256', 'Evidence snapshot digest'],
    ['provenanceSha256', 'Evidence provenance digest'],
    ['releaseNotesSha256', 'Evidence release-notes digest'],
    ['renderedReleaseBodySha256', 'Evidence rendered-body digest'],
  ]) {
    requireSha256(evidence[field], label)
    sameValue(evidence[field], bindings[field], label)
  }

  const evidenceAssets = sortedReleaseAssets(evidence.assets)
  const boundAssets = sortedReleaseAssets(bindings.assets)
  requireValue(
    JSON.stringify(evidenceAssets) === JSON.stringify(boundAssets),
    'Evidence asset set does not match the staged release snapshot.'
  )

  requireValue(Array.isArray(evidence.gates), 'Release gate evidence does not contain a gate matrix.')
  const gateIds = evidence.gates.map((gate) => gate?.gateId)
  requireValue(new Set(gateIds).size === gateIds.length, 'Release gate evidence contains a duplicate gate ID.')
  requireValue(
    JSON.stringify([...gateIds].sort()) === JSON.stringify([...REQUIRED_GO_LIVE_GATE_IDS_V1].sort()),
    'Release gate evidence gate set does not exactly match org.roachnet.go-live-gates.v1.'
  )

  for (const gate of evidence.gates) {
    requireValue(gate.result === 'PASS', `Release gate ${gate.gateId} must be PASS.`)
    sameValue(gate.candidateSha, bindings.candidateSha, `Release gate ${gate.gateId} candidate SHA`)
    sameValue(gate.artifactSha256, bindings.artifactSha256, `Release gate ${gate.gateId} artifact digest`)
    requireValue(Number.isSafeInteger(gate.runId) && gate.runId > 0, `Release gate ${gate.gateId} has an invalid run ID.`)
    requireValue(Number.isSafeInteger(gate.runAttempt) && gate.runAttempt > 0, `Release gate ${gate.gateId} has an invalid run attempt.`)
    requireValue(
      typeof gate.checkName === 'string' && gate.checkName.trim().length > 0 && !/[\r\n\t]/.test(gate.checkName),
      `Release gate ${gate.gateId} has an invalid check name.`
    )
    requireValue(
      gate.evidenceUri === `https://github.com/RoachWares/RoachNet/actions/runs/${gate.runId}` ||
        gate.evidenceUri.startsWith(`https://github.com/RoachWares/RoachNet/actions/runs/${gate.runId}/`),
      `Release gate ${gate.gateId} evidence URI is not bound to its exact run ID.`
    )
    requireSha256(gate.evidenceSha256, `Release gate ${gate.gateId} evidence`)
  }
  return true
}

export function finalizeReleaseGateEvidence(results, bindings) {
  validateReleaseGateResults(results, bindings)
  const evidence = {
    schema: 'org.roachnet.release-gate-evidence.v1',
    policy: results.policy,
    repository: bindings.repository,
    candidateSha: bindings.candidateSha,
    tag: bindings.tag,
    artifactSha256: bindings.artifactSha256,
    stageWorkflow: {
      path: bindings.stageWorkflowPath,
      runId: bindings.stageRunId,
      runAttempt: bindings.stageRunAttempt,
    },
    releaseId: bindings.releaseId,
    snapshotSha256: bindings.snapshotSha256,
    provenanceSha256: bindings.provenanceSha256,
    releaseNotesSha256: bindings.releaseNotesSha256,
    renderedReleaseBodySha256: bindings.renderedReleaseBodySha256,
    assets: sortedReleaseAssets(bindings.assets),
    gates: results.gates,
  }
  validateReleaseGateEvidence(evidence, bindings)
  return evidence
}

export function releaseGateBindings({ provenance, snapshot, snapshotSha256 }) {
  return {
    repository: 'RoachWares/RoachNet',
    candidateSha: provenance.candidateSha,
    tag: provenance.tag,
    artifactSha256: provenance.artifact.sha256,
    stageWorkflowPath: provenance.workflow.path,
    stageRunId: provenance.workflow.runId,
    stageRunAttempt: provenance.workflow.runAttempt,
    releaseId: snapshot.releaseId,
    snapshotSha256,
    provenanceSha256: snapshot.provenanceSha256,
    releaseNotesSha256: provenance.releaseNotes.sha256,
    renderedReleaseBodySha256: provenance.renderedReleaseBody.sha256,
    assets: snapshot.assets,
  }
}
