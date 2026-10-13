import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  shouldRegenerateIOSProject,
  validateIOSCompanionCheckout,
} from '../smoke-test-ios-companion-compat.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..', '..')

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

test('native package carries the repository license and reports its actual SPDX identifier', () => {
  const source = readRepoFile('scripts/build-native-macos-apps.mjs')
  const packageManifest = JSON.parse(readRepoFile('package.json'))
  const packageLock = JSON.parse(readRepoFile('package-lock.json'))
  const license = readRepoFile('LICENSE')

  assert.equal(packageManifest.license, 'Apache-2.0')
  assert.equal(packageLock.packages[''].license, packageManifest.license)
  assert.equal(license.includes('Apache License, Version 2.0'), true)
  assert.match(source, /cp\(path\.join\(repoRoot, 'LICENSE'\), path\.join\(resourcesPath, 'LICENSE'\)\)/)
  assert.match(source, /is missing Contents\/Resources\/LICENSE/)
})

test('companion compatibility smoke runs only the native runtime', () => {
  const source = readRepoFile('scripts/smoke-test-ios-companion-compat.mjs')

  assert.match(source, /ROACHNET_NATIVE_API_BINARY/)
  assert.match(source, /'Contents', 'Helpers', 'roachnet-runtime'/)
  assert.match(source, /path\.join\(logsRoot,\s*'roachnet-native-api\.log'\)/)
  assert.match(source, /readRuntimeBaseUrl/)
  assert.doesNotMatch(source, /run-roachnet|EmbeddedRuntime|ROACHNET_NODE_BINARY|process\.execPath/)
})

test('iOS companion smoke uses a tracked project by default and binds candidate validation to a clean exact SHA', () => {
  const exactSha = 'a'.repeat(40)
  const fakeGit = (_command, args) => {
    if (args.at(-1) === '--is-inside-work-tree') return 'true\n'
    if (args.includes('ls-files')) return 'RoachNetCompanion.xcodeproj/project.pbxproj\n'
    if (args.at(-1) === 'HEAD') return `${exactSha}\n`
    if (args.includes('status')) return ''
    throw new Error(`Unexpected git invocation: ${args.join(' ')}`)
  }

  assert.equal(shouldRegenerateIOSProject({}), false)
  assert.equal(shouldRegenerateIOSProject({ ROACHNET_REGENERATE_XCODEPROJ: '1' }), true)
  const source = readRepoFile('scripts/smoke-test-ios-companion-compat.mjs')
  assert.match(source, /async function regenerateIOSProjectIfRequested/)
  assert.match(source, /if \(!shouldRegenerateIOSProject\(env\)\) return/)
  assert.doesNotMatch(source, /await runSmokeCommand\('ruby', \[path\.join\(iosRepoRoot, 'scripts', 'generate_xcodeproj\.rb'\)/)
  assert.equal(
    validateIOSCompanionCheckout({
      iosRepoRoot: '/fixture/RoachNet-iOS',
      projectPath: '/fixture/RoachNet-iOS/RoachNetCompanion.xcodeproj',
      env: { ROACHNET_CANDIDATE_BUILD: '1', ROACHNET_IOS_EXPECTED_SHA: exactSha },
      existsSyncImpl: () => true,
      execFileSyncImpl: fakeGit,
    }).sha,
    exactSha
  )

  assert.throws(
    () => validateIOSCompanionCheckout({
      iosRepoRoot: '/fixture/RoachNet-iOS',
      projectPath: '/fixture/RoachNet-iOS/RoachNetCompanion.xcodeproj',
      env: { ROACHNET_CANDIDATE_BUILD: '1' },
      existsSyncImpl: () => true,
      execFileSyncImpl: fakeGit,
    }),
    /ROACHNET_IOS_EXPECTED_SHA/
  )
  assert.throws(
    () => validateIOSCompanionCheckout({
      iosRepoRoot: '/fixture/RoachNet-iOS',
      projectPath: '/fixture/RoachNet-iOS/RoachNetCompanion.xcodeproj',
      env: { ROACHNET_IOS_EXPECTED_SHA: 'b'.repeat(40) },
      existsSyncImpl: () => true,
      execFileSyncImpl: fakeGit,
    }),
    /does not match/
  )
  assert.throws(
    () => validateIOSCompanionCheckout({
      iosRepoRoot: '/fixture/RoachNet-iOS',
      projectPath: '/fixture/RoachNet-iOS/RoachNetCompanion.xcodeproj',
      env: { ROACHNET_RELEASE_BUILD: '1', ROACHNET_IOS_EXPECTED_SHA: exactSha },
      existsSyncImpl: (target) => !target.endsWith('RoachNetCompanion.xcodeproj'),
      execFileSyncImpl: fakeGit,
    }),
    /tracked iOS project/
  )
  assert.throws(
    () => validateIOSCompanionCheckout({
      iosRepoRoot: '/fixture/RoachNet-iOS',
      projectPath: '/fixture/RoachNet-iOS/RoachNetCompanion.xcodeproj',
      env: { ROACHNET_RELEASE_BUILD: '1', ROACHNET_IOS_EXPECTED_SHA: exactSha },
      existsSyncImpl: () => true,
      execFileSyncImpl: (_command, args) => args.includes('status') ? ' M Core/CompanionModels.swift\n' : fakeGit(_command, args),
    }),
    /must be clean/
  )
})

test('legacy admin source and CI lane are absent from the public candidate', () => {
  assert.equal(existsSync(path.join(repoRoot, 'admin')), false)
  assert.equal(existsSync(path.join(repoRoot, '.github/workflows/build-admin-on-pr.yml')), false)
})

test('runtime freshness audit explains stale dist rebuild failures without weakening the gate', () => {
  const source = readRepoFile('scripts/audit-runtime-freshness.mjs')

  assert.match(source, /native\/macos\/dist predates the native Swift runtime/)
  assert.match(source, /ROACHNET_REQUIRE_FRESH_DIST === '1'/)
  assert.match(source, /must not carry a Node runtime/)
})

test('upstream project audit treats default branch movement as non-blocking context', () => {
  const source = readRepoFile('scripts/audit-upstream-projects.mjs')

  assert.match(source, /stable release metadata is unchanged and remains the blocking gate/)
  assert.match(source, /ROACHNET_UPSTREAM_VERBOSE/)
  assert.doesNotMatch(source, /console\.warn/)
})
