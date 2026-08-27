import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  auditReleaseConfiguration,
  exactActorIsAuthorized,
  validateCandidateIdentity,
} from '../audit-release-configuration.mjs'
import { resolveBuildModes } from '../build-native-macos-apps.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

test('public release configuration has no unsigned stable publication bypass', () => {
  const failures = auditReleaseConfiguration()
  assert.deepEqual(failures, [])
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
      version: '1.0.6',
      buildNumber: 106,
      tag: 'v1.0.6',
      candidateSha: 'a'.repeat(40),
      checkoutSha: 'a'.repeat(40),
      tagSha: 'a'.repeat(40),
    }),
    []
  )

  const failures = validateCandidateIdentity({
    version: '1.0.5',
    buildNumber: 105,
    tag: 'v1.0.5',
    candidateSha: 'a'.repeat(40),
    checkoutSha: 'b'.repeat(40),
    tagSha: 'c'.repeat(40),
  })
  assert.ok(failures.some((failure) => failure.includes('greater than 1.0.5')))
  assert.ok(failures.some((failure) => failure.includes('greater than 105')))
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
  assert.match(builder, /if \(pinnedRuntimeBuild\)\s*\{[\s\S]*?runtimePins\.ollama/)
  assert.match(builder, /if \(pinnedRuntimeBuild\) await requireFileSha256\(archivePath, release\.sha256, `Ollama \$\{release\.version\}`\)/)
  assert.match(builder, /const codesignIdentity = releaseBuild \? process\.env\.ROACHNET_CODESIGN_IDENTITY\?\.trim\(\) \|\| '' : ''/)
  assert.match(builder, /async function notarizeArtifact\(artifactPath\) \{\s*if \(candidateBuild\) \{\s*return/)
  assert.match(builder, /if \(releaseBuild && \(!codesignIdentity \|\| !notaryProfile \|\| skipDmg\)\)/)
  assert.match(builder, /if \(releaseBuild\) \{\s*throw new Error\('Public release builds require Developer ID signing and a configured notary profile\.'/)
})
