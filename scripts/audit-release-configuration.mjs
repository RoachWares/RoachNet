#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const stableVersion = [1, 0, 5]
const stableBuildNumber = 105

function read(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

function listFiles(relativeRoot, extensionPattern) {
  const root = path.join(repoRoot, relativeRoot)
  const results = []
  function walk(currentPath) {
    for (const entry of readdirSync(currentPath, { withFileTypes: true })) {
      const entryPath = path.join(currentPath, entry.name)
      if (entry.isDirectory()) walk(entryPath)
      else if (extensionPattern.test(entry.name)) results.push(path.relative(repoRoot, entryPath))
    }
  }
  walk(root)
  return results.sort()
}

function compareVersions(left, right) {
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const difference = (left[index] || 0) - (right[index] || 0)
    if (difference !== 0) return difference
  }
  return 0
}

export function exactActorIsAuthorized(rawAllowlist, actor) {
  return String(rawAllowlist || '')
    .split(/[\s,]+/)
    .map((entry) => entry.trim())
    .filter(Boolean)
    .some((entry) => entry === actor)
}

export function validateCandidateIdentity({
  version,
  buildNumber,
  tag,
  candidateSha,
  checkoutSha,
  tagSha,
}) {
  const failures = []
  const parsedVersion = /^\d+\.\d+\.\d+$/.test(String(version || ''))
    ? String(version).split('.').map(Number)
    : []
  if (parsedVersion.length !== 3 || compareVersions(parsedVersion, stableVersion) <= 0) {
    failures.push('Candidate version must be greater than 1.0.5.')
  }
  if (!Number.isSafeInteger(Number(buildNumber)) || Number(buildNumber) <= stableBuildNumber) {
    failures.push('Candidate build number must be greater than 105.')
  }
  if (tag !== `v${version}`) failures.push('Candidate tag must exactly match v<package version>.')
  if (!/^[a-f0-9]{40}$/i.test(String(candidateSha || ''))) {
    failures.push('Candidate SHA must be a full 40-character commit SHA.')
  }
  if (candidateSha !== checkoutSha) failures.push('Checkout does not resolve to the candidate SHA.')
  if (candidateSha !== tagSha) failures.push('Candidate tag target does not resolve to the candidate SHA.')
  return failures
}

function requirePattern(failures, source, pattern, message) {
  if (!pattern.test(source)) failures.push(message)
}

function requireOrder(failures, source, markers, label) {
  let previous = -1
  for (const marker of markers) {
    const index = source.indexOf(marker)
    if (index === -1) {
      failures.push(`${label} is missing required step: ${marker}`)
      return
    }
    if (index <= previous) {
      failures.push(`${label} runs release gates in the wrong order near: ${marker}`)
      return
    }
    previous = index
  }
}

function auditActionPins(failures, source, label) {
  for (const line of source.split(/\r?\n/)) {
    const match = line.match(/^\s*-?\s*uses:\s*([^\s#]+)(?:\s+#.*)?$/)
    if (!match) continue
    const reference = match[1]
    if (!/@[a-f0-9]{40}$/i.test(reference)) {
      failures.push(`${label} action is not pinned to an immutable commit: ${reference}`)
    }
  }
}

export function auditReleaseConfiguration() {
  const failures = []
  const nativeWorkflow = read('.github/workflows/native-packages.yml')
  const promotionWorkflow = read('.github/workflows/release.yml')
  const packageManifest = JSON.parse(read('package.json'))
  const packageLock = JSON.parse(read('package-lock.json'))
  const buildScript = read('scripts/build-native-macos-apps.mjs')
  const runtimePins = JSON.parse(read('docs/release-gates/runtime-freshness.json'))

  auditActionPins(failures, nativeWorkflow, 'native-packages.yml')
  auditActionPins(failures, promotionWorkflow, 'release.yml')

  if (existsSync(path.join(repoRoot, '.releaserc.json'))) {
    failures.push('.releaserc.json must be absent; semantic-release is not an approved publication path.')
  }
  if (/semantic-release|contains\(secrets\.DEPLOYMENT_AUTHORIZED_USERS/i.test(`${nativeWorkflow}\n${promotionWorkflow}`)) {
    failures.push('Release workflows must not use semantic-release or substring actor authorization.')
  }
  if (/--clobber|git\s+tag\s+-f|git\s+push[^\n]*--force/i.test(`${nativeWorkflow}\n${promotionWorkflow}`)) {
    failures.push('Release workflows must not clobber assets or mutate tags.')
  }

  for (const workflowPath of listFiles('.github/workflows', /\.ya?ml$/)) {
    if (['.github/workflows/native-packages.yml', '.github/workflows/release.yml'].includes(workflowPath)) continue
    const source = read(workflowPath)
    if (/semantic-release|gh\s+release\s+(?:create|upload|edit)|--clobber|git\s+tag|releases\.create|uploadReleaseAsset|action-gh-release|release-action/i.test(source)) {
      failures.push(`Unapproved release-capable workflow path: ${workflowPath}`)
    }
  }

  requirePattern(failures, nativeWorkflow, /environment:\s*roachnet-release-staging/, 'Staging requires the protected roachnet-release-staging environment.')
  requirePattern(failures, promotionWorkflow, /environment:\s*roachnet-release-production/, 'Promotion requires the protected roachnet-release-production environment.')
  requirePattern(failures, nativeWorkflow, /group:\s*roachnet-public-release/, 'Staging lacks the serialized public-release concurrency lock.')
  requirePattern(failures, promotionWorkflow, /group:\s*roachnet-public-release/, 'Promotion lacks the serialized public-release concurrency lock.')
  requirePattern(failures, nativeWorkflow, /DEPLOYMENT_AUTHORIZED_USERS/, 'Staging lacks an exact actor allowlist gate.')
  requirePattern(failures, promotionWorkflow, /DEPLOYMENT_AUTHORIZED_USERS/, 'Promotion lacks an exact actor allowlist gate.')
  requirePattern(failures, nativeWorkflow, /APPLE_DEVELOPER_ID_APP_CERT_BASE64[\s\S]*APPLE_NOTARY_TEAM_ID/, 'Staging does not fail closed on all Apple signing/notary prerequisites.')
  requirePattern(failures, nativeWorkflow, /ROACHNET_RELEASE_BUILD:\s*['"]?1/, 'Staging does not enable fail-closed release build mode.')
  requirePattern(failures, nativeWorkflow, /GITHUB_SHA[\s\S]*CANDIDATE_SHA/, 'Staging is not dispatched from the exact candidate SHA.')
  requirePattern(failures, nativeWorkflow, /roachnet-release-staging[\s\S]*required_reviewers/, 'Staging does not verify protected-environment reviewers.')
  requirePattern(failures, nativeWorkflow, /workflowRunId[\s\S]*workflowRunAttempt[\s\S]*workflowPath[\s\S]*assets/, 'Staging provenance does not bind every asset to the Actions run.')
  requirePattern(failures, nativeWorkflow, /roachnet-release-provenance-\$\{\{ inputs\.candidate_sha \}\}-\$\{\{ github\.run_attempt \}\}/, 'Staging does not preserve attempt-specific immutable run-bound provenance.')
  requirePattern(failures, promotionWorkflow, /roachnet-release-production[\s\S]*required_reviewers/, 'Promotion does not verify protected-environment reviewers.')
  requirePattern(failures, promotionWorkflow, /actions\/runs\/\$STAGE_RUN_ID[\s\S]*gh run download/, 'Promotion does not authenticate provenance against a successful stage run.')
  requirePattern(failures, promotionWorkflow, /asset\.digest[\s\S]*gh release edit/, 'Promotion does not revalidate live remote asset digests immediately before publication.')

  requireOrder(failures, nativeWorkflow, [
    'npm ci',
    'npm test',
    'npm run native:test',
    'npm run native:dist',
    'npm run smoke:release-gates',
    'codesign --verify',
    'xcrun notarytool history',
    'stapler validate',
    'spctl --assess',
    'shasum -a 256 -c RoachNet-Setup-macOS.dmg.sha256',
    'generate-release-supply-chain.mjs',
    'audit-release-supply-chain.mjs',
    'gh release create',
    'gh release upload',
  ], 'native-packages.yml')
  requirePattern(failures, nativeWorkflow, /gh release create[^\n]*--draft[^\n]*--prerelease/, 'Staging may only create a draft prerelease.')

  requireOrder(failures, promotionWorkflow, [
    'gh release download',
    'shasum -a 256 -c RoachNet-Setup-macOS.dmg.sha256',
    'codesign --verify',
    'xcrun notarytool history',
    'stapler validate',
    'spctl --assess',
    'audit-release-supply-chain.mjs',
    'gh release edit "$RELEASE_TAG" --draft=false --prerelease=false',
  ], 'release.yml')
  if (/gh release (?:create|upload)/.test(promotionWorkflow)) {
    failures.push('Promotion workflow must only promote exact staged bytes; it cannot create or upload assets.')
  }

  const identityFailures = validateCandidateIdentity({
    version: packageManifest.version,
    buildNumber: packageManifest.buildNumber,
    tag: `v${packageManifest.version}`,
    candidateSha: 'a'.repeat(40),
    checkoutSha: 'a'.repeat(40),
    tagSha: 'a'.repeat(40),
  })
  failures.push(...identityFailures)
  if (packageLock.version !== packageManifest.version || packageLock.packages?.['']?.version !== packageManifest.version) {
    failures.push('package-lock.json version metadata does not match package.json.')
  }
  requirePattern(failures, buildScript, /CFBundleVersion<\/key>\s*\n\s*<string>\$\{appBuildNumber\}<\/string>/, 'App/setup CFBundleVersion is not sourced from the intentional build number.')
  requirePattern(failures, buildScript, /ROACHNET_RELEASE_BUILD/, 'Native builder lacks fail-closed release mode.')

  for (const [label, value] of [
    ['Node arm64', runtimePins.node?.artifacts?.darwinArm64?.sha256],
    ['Node x64', runtimePins.node?.artifacts?.darwinX64?.sha256],
    ['Ollama macOS', runtimePins.ollama?.artifact?.sha256],
  ]) {
    if (!/^[a-f0-9]{64}$/i.test(String(value || ''))) failures.push(`${label} runtime artifact is not checksum-pinned.`)
  }

  if (existsSync(path.join(repoRoot, 'admin'))) {
    failures.push('Legacy admin/ remains in the public candidate source surface.')
  }

  return failures
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const failures = auditReleaseConfiguration()
  if (failures.length > 0) {
    console.error('Release configuration audit failed:')
    for (const failure of failures) console.error(`- ${failure}`)
    process.exitCode = 1
  } else {
    console.log('Release configuration audit passed.')
  }
}
