import assert from 'node:assert/strict'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// RoachNet, RoachNet Setup and roachnet-runtime are Swift only (ROA-78): no
// Node ships with them and nothing in them looks for, switches to or starts
// one. Node is only the toolchain for the scripts in this folder.

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const read = (relativePath) => readFileSync(path.join(repoRoot, relativePath), 'utf8')

function swiftSources(folder = path.join(repoRoot, 'native', 'macos', 'Sources')) {
  return readdirSync(folder, { withFileTypes: true }).flatMap((entry) => {
    const entryPath = path.join(folder, entry.name)
    if (entry.isDirectory()) return swiftSources(entryPath)
    return entry.name.endsWith('.swift') ? [entryPath] : []
  })
}

test('the JavaScript runtimes, Electron shells and Docker install lane are gone', () => {
  for (const retired of [
    'scripts/run-roachnet-native-api.mjs',
    'scripts/run-roachnet.mjs',
    'scripts/run-roachnet-setup.mjs',
    'scripts/roachnet-companion-server.mjs',
    'desktop',
    'installer',
    'setup-ui',
    'install',
    'ops',
    'Dockerfile',
    'app.js',
  ]) {
    assert.equal(existsSync(path.join(repoRoot, retired)), false, `${retired} should be retired`)
  }
  const manifest = JSON.parse(read('package.json'))
  assert.equal(manifest.main, undefined, 'package.json names no JavaScript entry point')
  for (const [name, command] of Object.entries(manifest.scripts)) {
    assert.doesNotMatch(command, /run-roachnet|companion-server|electron/, `npm script ${name} must not start a JavaScript runtime`)
  }
})

test('the apps only launch the Swift runtime helper', () => {
  const offenders = []
  for (const filePath of swiftSources()) {
    const lines = readFileSync(filePath, 'utf8').split('\n')
    lines.forEach((line, index) => {
      if (/removeValue\(forKey:/.test(line)) return // stripping an inherited variable is fine
      // (EmbeddedRuntime/roachspeech is an older speech-model folder, not Node.)
      if (/preferred(?:Portable)?NodeBinary|EmbeddedRuntime\/node|ROACHNET_FORCE_NODE_RUNTIME|ROACHNET_NODE_BINARY|bundledRepositoryArchive|bin\/node\b/.test(line)) {
        offenders.push(`${path.relative(repoRoot, filePath)}:${index + 1}: ${line.trim()}`)
      }
    })
  }
  assert.deepEqual(offenders, [])

  const core = read('native/macos/Sources/RoachNetCore/ManagedAppRuntime.swift')
  assert.match(core, /RoachNet could not find its native runtime helper/)
  const setup = read('native/macos/Sources/RoachNetSetup/main.swift')
  assert.match(setup, /RoachNet Setup is missing its native setup service \(roachnet-runtime\)/)
})

test('the builder refuses any bundle that carries Node, JavaScript or RoachNet source', () => {
  const build = read('scripts/build-native-macos-apps.mjs')
  assert.match(build, /forbiddenBundleExtensions = new Set\(\['\.js', '\.mjs', '\.cjs', '\.node'\]\)/)
  assert.match(build, /forbiddenBundleNames = new Set\(\['node_modules', 'RoachNetSource', 'RoachNetSource\.tar\.gz'\]\)/)
  assert.match(build, /assertNoNodeOrJavaScript\(desktopBundlePath, 'RoachNet'\)/)
  assert.match(build, /assertNoNodeOrJavaScript\(setupBundlePath, 'RoachNet Setup'\)/)
  assert.doesNotMatch(build, /nodejs\.org\/dist|EmbeddedRuntime|ROACHNET_BUNDLE_NODE_COMPAT|ROACHNET_BUNDLE_OPENCLAW/)

  const pins = JSON.parse(read('docs/release-gates/runtime-freshness.json'))
  assert.equal(pins.node.mode, 'not-shipped')
  assert.equal(pins.node.artifacts, undefined)
  assert.equal(pins.openclaw.mode, 'external-not-bundled')
})
