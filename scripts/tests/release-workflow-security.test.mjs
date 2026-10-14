import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  auditNativeConcurrency,
  auditReleaseConfiguration,
  exactActorIsAuthorized,
  validateCandidateIdentity,
  workflowJob,
} from '../audit-release-configuration.mjs'
import { resolveBuildModes, resolveSourceCommit } from '../build-native-macos-apps.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

test('public release configuration has no unsigned stable publication bypass', () => {
  const failures = auditReleaseConfiguration()
  assert.deepEqual(failures, [])
})

test('diagnostic runs have their own concurrency group and staging keeps the release lock (ROA-96)', () => {
  const workflow = readFileSync(path.join(repoRoot, '.github', 'workflows', 'native-packages.yml'), 'utf8')
  assert.deepEqual(auditNativeConcurrency(workflow), [])
  assert.match(workflowJob(workflow, 'stage-release'), /group: roachnet-public-release/)
  assert.doesNotMatch(workflowJob(workflow, 'diagnostic'), /group: roachnet-public-release/)

  const workflowLevel = workflow.replace('jobs:\n', 'concurrency:\n  group: roachnet-public-release\n  cancel-in-progress: false\n\njobs:\n')
  assert.ok(auditNativeConcurrency(workflowLevel).some((failure) => failure.includes('per job')))

  const sharedDiagnostic = workflow.replace(/(\n {4}concurrency:\n {6}group: )roachnet-native-diagnostic-[^\n]+/, '$1roachnet-public-release')
  assert.notEqual(sharedDiagnostic, workflow)
  assert.ok(auditNativeConcurrency(sharedDiagnostic).some((failure) => failure.includes('Diagnostic runs')))

  const unlockedStage = workflow.replace(/(stage-release:[\s\S]*?\n {4}concurrency:\n {6}group: )roachnet-public-release/, '$1roachnet-stage')
  assert.notEqual(unlockedStage, workflow)
  assert.ok(auditNativeConcurrency(unlockedStage).some((failure) => failure.includes('Staging lacks')))
})

test('release authorization compares complete actor names', () => {
  assert.equal(exactActorIsAuthorized('roach,roachwares-bot', 'roach'), true)
  assert.equal(exactActorIsAuthorized('roach,roachwares-bot', 'roachwares-bot'), true)
  assert.equal(exactActorIsAuthorized('roach,roachwares-bot', 'roachwares'), false)
  assert.equal(exactActorIsAuthorized('roach,roachwares-bot', 'ach'), false)
})

test('candidate identity requires a new exact version, build, tag, and SHA', () => {
  assert.deepEqual(
    validateCandidateIdentity({
      version: '1.1.0',
      buildNumber: 110,
      tag: 'v1.1.0',
      candidateSha: 'a'.repeat(40),
      checkoutSha: 'a'.repeat(40),
      tagSha: 'a'.repeat(40),
    }),
    []
  )

  const failures = validateCandidateIdentity({
    version: '1.0.7',
    buildNumber: 107,
    tag: 'v1.0.7',
    candidateSha: 'a'.repeat(40),
    checkoutSha: 'b'.repeat(40),
    tagSha: 'c'.repeat(40),
  })
  assert.ok(failures.some((failure) => failure.includes('greater than 1.0.7')))
  assert.ok(failures.some((failure) => failure.includes('greater than 107')))
  assert.ok(failures.some((failure) => failure.includes('candidate SHA')))
  assert.ok(failures.some((failure) => failure.includes('tag target')))
})

test('candidate build pins runtime payloads without weakening public release signing requirements', () => {
  assert.deepEqual(resolveBuildModes({ ROACHNET_CANDIDATE_BUILD: '1' }), {
    releaseBuild: false,
    candidateBuild: true,
    pinnedRuntimeBuild: true,
  })
  assert.deepEqual(resolveBuildModes({ ROACHNET_RELEASE_BUILD: '1' }), {
    releaseBuild: true,
    candidateBuild: false,
    pinnedRuntimeBuild: true,
  })
  assert.deepEqual(resolveBuildModes({}), {
    releaseBuild: false,
    candidateBuild: false,
    pinnedRuntimeBuild: false,
  })
  assert.deepEqual(resolveBuildModes({ ROACHNET_RELEASE_BUILD: '1', ROACHNET_CANDIDATE_BUILD: '1' }), {
    releaseBuild: true,
    candidateBuild: false,
    pinnedRuntimeBuild: true,
  })

  const builder = readFileSync(path.join(repoRoot, 'scripts', 'build-native-macos-apps.mjs'), 'utf8')
  // RoachNet 1.1 retired the bundled Ollama runner: the builder must never fetch it again,
  // and it clears the Ollama and OpenClaw payloads older builds left behind.
  assert.doesNotMatch(builder, /ensureBundledOllamaCache|ollama-darwin\.tgz/)
  assert.match(builder, /for \(const stale of \['bundled-ollama\.tar\.gz', 'bundled-ollama', 'bundled-openclaw\.tar\.gz', 'openclaw-deferred\.marker'\]\) \{\s*discardPath/)
  assert.match(builder, /const codesignIdentity = releaseBuild \? process\.env\.ROACHNET_CODESIGN_IDENTITY\?\.trim\(\) \|\| '' : ''/)
  assert.match(builder, /async function notarizeArtifact\(artifactPath\) \{\s*if \(candidateBuild\) \{\s*return/)
  assert.match(builder, /if \(releaseBuild && \(!codesignIdentity \|\| !notaryProfile \|\| skipDmg\)\)/)
  assert.match(builder, /if \(releaseBuild\) \{\s*throw new Error\('Public release builds require Developer ID signing and a configured notary profile\.'/)
})

test('builds stamp a full source commit and refuse a malformed override (ROA-40)', () => {
  const sha = '0123456789abcdef0123456789abcdef01234567'
  assert.equal(resolveSourceCommit({ ROACHNET_SOURCE_COMMIT: sha }), sha)
  assert.equal(resolveSourceCommit({ ROACHNET_SOURCE_COMMIT: `${sha}-dirty` }), `${sha}-dirty`)
  assert.throws(() => resolveSourceCommit({ ROACHNET_SOURCE_COMMIT: sha.slice(0, 12) }))
  assert.throws(() => resolveSourceCommit({ ROACHNET_SOURCE_COMMIT: `${sha}</string>` }))
  assert.match(resolveSourceCommit({}), /^([0-9a-f]{40}(-dirty)?)?$/)
})

test('the stage job scopes Apple secrets to the steps that use them (ROA-40)', () => {
  const workflow = readFileSync(path.join(repoRoot, '.github', 'workflows', 'native-packages.yml'), 'utf8')
  const stageJob = workflow.slice(workflow.indexOf('name: Build, verify, and quarantine signed RC'))
  const jobEnv = stageJob.slice(stageJob.indexOf('\n    env:'), stageJob.indexOf('\n    steps:'))
  assert.ok(jobEnv.length > 0, 'stage job env block not found')
  assert.doesNotMatch(jobEnv, /secrets\./, 'stage job-level env must not carry secrets')
  assert.match(stageJob, /npm ci --ignore-scripts/)
  const installStep = stageJob.slice(stageJob.indexOf('- name: Install dependencies'), stageJob.indexOf('- name: Run engineering'))
  assert.doesNotMatch(installStep, /APPLE_/)
  for (const step of ['Import Developer ID certificate', 'Configure notarization profile']) {
    const body = stageJob.slice(stageJob.indexOf(`- name: ${step}`))
    assert.match(body.slice(0, body.indexOf('run: |')), /secrets\.APPLE_/, `${step} must receive its secrets at step level`)
  }
})
