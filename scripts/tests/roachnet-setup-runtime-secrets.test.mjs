import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..', '..')

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

test('setup app forwards legacy-compatible runtime database secrets into the smoke launcher', () => {
  const source = readRepoFile('scripts/run-roachnet-setup.mjs')
  const escapedMysqlRootReference = '$' + '\\' + '${MYSQL_ROOT_PASSWORD}'
  const unsafeMysqlRootReference = '$' + '\\\\' + '${MYSQL_ROOT_PASSWORD}'

  assert.match(source, /LEGACY_MANAGED_RUNTIME_DB_PASSWORD/)
  assert.match(source, /LEGACY_MANAGED_RUNTIME_DB_ROOT_PASSWORD/)
  assert.doesNotMatch(source, /LEGACY_MANAGED_RUNTIME_DB_(?:ROOT_)?PASSWORD\s*=\s*['"][0-9a-f]{32}['"]/i)
  assert.match(source, /existingValues\.MYSQL_ROOT_PASSWORD/)
  assert.match(source, /MYSQL_ROOT_PASSWORD:\s*dbRootPassword/)
  assert.match(source, /ROACHNET_DB_ROOT_PASSWORD:\s*dbRootPassword/)
  assert.equal(source.includes(`mysqladmin ping -h 127.0.0.1 -p\\\\"${escapedMysqlRootReference}\\\\"`), true)
  assert.equal(source.includes(`-p${unsafeMysqlRootReference}`), false)
})

test('runtime launch env exposes both RoachNet and MySQL root password names', () => {
  const source = readRepoFile('scripts/run-roachnet.mjs')

  assert.match(source, /envValues\.MYSQL_ROOT_PASSWORD\?\.trim\(\)/)
  assert.match(source, /ROACHNET_DB_ROOT_PASSWORD:\s*runtimeSecrets\.dbRootPassword/)
  assert.match(source, /MYSQL_ROOT_PASSWORD:\s*runtimeSecrets\.dbRootPassword/)
  assert.match(source, /const managedEnv = getManagedRuntimeEnvValues\(envValues\)[\s\S]*?composeUpRoachNetServices\([\s\S]*?env:\s*managedEnv/)
})

test('managed compose healthcheck uses the variable actually present in the mysql container', () => {
  const compose = readRepoFile('ops/roachnet-management.compose.yml')

  assert.match(compose, /MYSQL_ROOT_PASSWORD:\s*"\$\{ROACHNET_DB_ROOT_PASSWORD\}"/)
  assert.match(compose, /ROACHNET_DB_ROOT_PASSWORD:\s*"\$\{ROACHNET_DB_ROOT_PASSWORD\}"/)
  assert.match(compose, /admin:[\s\S]*?MYSQL_ROOT_PASSWORD:\s*"\$\{ROACHNET_DB_ROOT_PASSWORD\}"/)
  assert.match(compose, /mysqladmin ping -h 127\.0\.0\.1 -p\\?"\$\$\{MYSQL_ROOT_PASSWORD\}\\?"/)
})

test('native package no longer stages the legacy admin bundled env', () => {
  const source = readRepoFile('scripts/build-native-macos-apps.mjs')
  const setupSource = readRepoFile('scripts/run-roachnet-setup.mjs')

  assert.match(source, /'admin\/'/)
  assert.doesNotMatch(source, /bundledEnvValues/)
  assert.doesNotMatch(source, /bundled-admin-build-node-modules/)
  assert.match(setupSource, /path\.join\(repoPath,\s*'runtime',\s*'roachnet\.env'\)/)
  assert.doesNotMatch(setupSource, /path\.join\(adminPath,\s*'\\.env'\)/)
})

test('native package trims installer-only source and build-only Node runtime payloads', () => {
  const source = readRepoFile('scripts/build-native-macos-apps.mjs')

  assert.match(source, /bundledSourceDirectoryExcludes/)
  assert.match(source, /'tests\/'/)
  assert.match(source, /'smoke-test-\*\.mjs'/)
  assert.match(source, /'audit-\*\.mjs'/)
  assert.match(source, /await syncTree\(sourcePath,\s*targetPath,\s*bundledSourceDirectoryExcludes\)/)
  assert.match(source, /function pruneEmbeddedNodeRuntimePayload/)
  assert.match(source, /'include'/)
  assert.match(source, /await pruneNodeRuntimePayload\(path\.join\(nodeRuntimeRoot,\s*'lib',\s*'node_modules'\)\)/)
})

test('native package carries the repository license and reports its actual SPDX identifier', () => {
  const source = readRepoFile('scripts/build-native-macos-apps.mjs')
  const packageManifest = JSON.parse(readRepoFile('package.json'))
  const packageLock = JSON.parse(readRepoFile('package-lock.json'))
  const license = readRepoFile('LICENSE')

  assert.equal(packageManifest.license, 'Apache-2.0')
  assert.equal(packageLock.packages[''].license, packageManifest.license)
  assert.equal(license.includes('Apache License, Version 2.0'), true)
  assert.equal(source.includes("'LICENSE',"), true)
})

test('companion compatibility smoke prefers the dependency-free native API launcher', () => {
  const source = readRepoFile('scripts/smoke-test-ios-companion-compat.mjs')

  assert.match(source, /run-roachnet-native-api\.mjs/)
  assert.match(source, /path\.join\(logsRoot,\s*'roachnet-native-api\.log'\)/)
  assert.match(source, /readRuntimeBaseUrl/)
  assert.doesNotMatch(source, /run-roachnet\.mjs/)
  assert.doesNotMatch(source, /path\.join\(logsRoot,\s*'admin\.log'\)/)
})

test('setup overwrite flow preserves storage before deleting the previous install backup', () => {
  const source = readRepoFile('scripts/run-roachnet-setup.mjs')

  assert.match(source, /preserveExistingStorageFromBackup/)
  assert.match(source, /isPathInsideRoot\(storagePath,\s*finalInstallPath\)/)
  assert.match(source, /await movePath\(backupStoragePath,\s*storagePath\)/)
  assert.match(source, /storagePath:\s*normalizedConfig\.storagePath/)
  assert.match(source, /Previous install backup retained/)
})

test('setup command failures include redacted stdout and stderr tails', () => {
  const source = readRepoFile('scripts/run-roachnet-setup.mjs')

  assert.match(source, /formatProcessFailure/)
  assert.match(source, /processOutputFailureSummary/)
  assert.match(source, /redactSensitiveText\(String\(stderr \|\| ''\)\.trim\(\), env\)/)
  assert.match(source, /redactSensitiveText\(String\(stdout \|\| ''\)\.trim\(\), env\)/)
  assert.match(source, /exited with code \$\{code\}/)
})

test('setup progress keeps long native install steps visibly alive and cleans scratch data', () => {
  const source = readRepoFile('scripts/run-roachnet-setup.mjs')

  assert.match(source, /currentStep:\s*'Checking the install lane\.'/)
  assert.match(source, /function setTaskStep/)
  assert.match(source, /async function withTaskActivity/)
  assert.match(source, /timer\.unref\?\.\(\)/)
  assert.match(source, /task\.currentStep = 'RoachNet is installed and ready\.'/)
  assert.match(source, /task\.currentStep = 'Setup failed\. Fix the issue and run install again\.'/)
  assert.match(source, /let stagingInstallPath = null/)
  assert.match(source, /await rm\(stagingInstallPath,\s*\{\s*recursive:\s*true,\s*force:\s*true\s*\}\)\.catch/)
  assert.match(source, /async function cleanupSetupWorkspace/)
  assert.match(source, /path\.join\(workspaceRoot,\s*'tmp'\)/)
  assert.match(source, /path\.join\(workspaceRoot,\s*'npm-cache'\)/)
  assert.match(source, /await cleanupSetupWorkspace\(stagedConfig\.installPath,\s*task\)/)
  assert.match(source, /await cleanupSetupWorkspace\(normalizedConfig\.installPath,\s*task\)/)
})

test('setup downloads are size-capped and harmless pkill no-match logs stay quiet', () => {
  const source = readRepoFile('scripts/run-roachnet-setup.mjs')

  assert.match(source, /SETUP_MAX_DOWNLOAD_BYTES/)
  assert.match(source, /downloadHttpToFile\(url,\s*destinationPath,[\s\S]*?maxDownloadBytes:\s*SETUP_MAX_DOWNLOAD_BYTES/)
  assert.match(source, /function isNoMatchingProcessFailure/)
  assert.match(source, /exit\(\?:ed\)\? with code 1/)
  assert.match(source, /Could not close \$\{label\} cleanly/)
  assert.match(source, /function roachNetProcessPatternsForTarget/)
  assert.match(source, /run-roachnet-native-api\.mjs/)
  assert.match(source, /roachnet-companion-server\.mjs/)
  assert.match(source, /await terminateRunningRoachNetApps\(task,\s*normalizedConfig\)/)
  assert.match(source, /await terminateRunningRoachNetApps\(task,\s*config\)/)
})

test('setup dependency diagnostics track the Node 26 native lane', () => {
  const source = readRepoFile('scripts/run-roachnet-setup.mjs')

  assert.match(source, /label:\s*'Node\.js 26'/)
  assert.match(source, /const minimumNodeVersion = '26\.0\.0'/)
  assert.match(source, /setup_26\.x/)
  assert.doesNotMatch(source, /Node\.js 24\+/)
  assert.doesNotMatch(source, /setup_24\.x/)
})

test('legacy admin source and CI lane are absent from the public candidate', () => {
  assert.equal(existsSync(path.join(repoRoot, 'admin')), false)
  assert.equal(existsSync(path.join(repoRoot, '.github/workflows/build-admin-on-pr.yml')), false)
})

test('runtime freshness audit explains stale dist rebuild failures without weakening the gate', () => {
  const source = readRepoFile('scripts/audit-runtime-freshness.mjs')

  assert.match(source, /native\/macos\/dist is stale after a runtime metadata update/)
  assert.match(source, /Rebuild the final app and DMG with scripts\/build-native-macos-apps\.mjs/)
  assert.match(source, /actualVersion === expectedVersion/)
})

test('upstream project audit treats default branch movement as non-blocking context', () => {
  const source = readRepoFile('scripts/audit-upstream-projects.mjs')

  assert.match(source, /stable release metadata is unchanged and remains the blocking gate/)
  assert.match(source, /ROACHNET_UPSTREAM_VERBOSE/)
  assert.doesNotMatch(source, /console\.warn/)
})
