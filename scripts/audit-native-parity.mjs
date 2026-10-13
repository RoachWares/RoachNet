#!/usr/bin/env node
import { readFileSync, existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const failures = []

function read(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

function requireFile(relativePath, description = relativePath) {
  if (!existsSync(path.join(repoRoot, relativePath))) {
    failures.push(`Missing ${description}: ${relativePath}`)
  }
}

function requirePattern(source, pattern, description) {
  if (!pattern.test(source)) {
    failures.push(`Missing native parity proof: ${description}`)
  }
}

function forbidPattern(source, pattern, description) {
  if (pattern.test(source)) {
    failures.push(`Forbidden native parity regression: ${description}`)
  }
}

requireFile('native/macos/Sources/RoachNetApp/main.swift', 'native app shell')
requireFile('native/macos/Sources/RoachNetApp/RoachNetSettingsView.swift', 'native settings window')
requireFile('native/macos/Sources/RoachNetApp/RoachNetAboutView.swift', 'native about window')
requireFile('native/macos/Sources/RoachNetApp/RoachArcadeView.swift', 'native RoachArcade')
requireFile('native/macos/Sources/RoachNetApp/RoachArchiveView.swift', 'native vault archive')
requireFile('native/macos/Sources/RoachNetApp/RoachMapsSupport.swift', 'native atlas')
requireFile('native/macos/Sources/RoachNetApp/DevWorkspaceView.swift', 'native dev workspace')
requireFile('native/macos/Sources/RoachNetSetup/main.swift', 'native setup app')
requireFile('native/macos/Sources/RoachNetRuntimeHost/main.swift', 'native runtime helper')

// RoachNet runs only Swift code: no JavaScript runtime, Electron shell or Node lookup remains (ROA-78).
for (const retired of ['scripts/run-roachnet-native-api.mjs', 'scripts/run-roachnet-setup.mjs', 'scripts/run-roachnet.mjs',
  'scripts/roachnet-companion-server.mjs', 'desktop', 'installer', 'setup-ui']) {
  if (existsSync(path.join(repoRoot, retired))) failures.push(`Retired JavaScript lane is back: ${retired}`)
}

const rootPackage = JSON.parse(read('package.json'))
if (rootPackage.main) {
  failures.push('Root package must not name a JavaScript entry point.')
}
for (const [scriptName, command] of Object.entries(rootPackage.scripts ?? {})) {
  if (/electron|electron-builder|desktop:|installer:|build:web|npm\s+--prefix\s+admin|run-roachnet\.mjs/i.test(`${scriptName} ${command}`)) {
    failures.push(`Root script still points at Electron/WebUI shipping lane: ${scriptName}`)
  }
}

const mainSource = read('native/macos/Sources/RoachNetApp/main.swift')
const settingsSource = read('native/macos/Sources/RoachNetApp/RoachNetSettingsView.swift')
const runtimeSource = read('native/macos/Sources/RoachNetCore/ManagedAppRuntime.swift')
const buildSource = read('scripts/build-native-macos-apps.mjs')
const setupAppSource = read('native/macos/Sources/RoachNetSetup/main.swift')
const locatorSource = read('native/macos/Sources/RoachNetCore/RuntimeModels.swift')

for (const pane of ['models', 'apps', 'updates', 'benchmark', 'support', 'legal', 'runtime']) {
  if (!settingsSource.includes(`case .${pane}:`)) {
    failures.push(`Missing native parity proof: settings switch renders native ${pane} pane`)
  }
  requirePattern(settingsSource, new RegExp(`case ${pane}\\b`), `native settings pane enum includes ${pane}`)
}

for (const method of [
  'checkLatestVersion',
  'getSystemUpdateStatus',
  'requestSystemUpdate',
  'getBenchmarkStatus',
  'runBenchmark',
]) {
  requirePattern(runtimeSource, new RegExp(`public func ${method}\\b`), `native runtime bridge exposes ${method}`)
}

for (const route of [
  '/settings/ai',
  '/settings/apps',
  '/settings/models',
  '/settings/update',
  '/settings/benchmark',
  '/settings/support',
  '/settings/legal',
  '/settings/system',
]) {
  requirePattern(mainSource, new RegExp(route.replaceAll('/', '\\/')), `native app maps ${route}`)
}

forbidPattern(mainSource, /openRoute\("\/settings\//, 'native app still opens internal settings routes in embedded WebUI')
forbidPattern(settingsSource, /openRoute\("\/settings\//, 'native settings still opens settings subpages through embedded WebUI')
forbidPattern(settingsSource, /Web Atlas/, 'settings still labels the native atlas path as Web Atlas')
forbidPattern(mainSource, /Web Atlas/, 'main shell still labels the native atlas path as Web Atlas')

requirePattern(buildSource, /assertNoNodeOrJavaScript\(desktopBundlePath/, 'packaged app is checked for Node and JavaScript')
requirePattern(buildSource, /assertNoNodeOrJavaScript\(setupBundlePath/, 'packaged setup app is checked for Node and JavaScript')
forbidPattern(buildSource, /ROACHNET_BUNDLE_NODE_COMPAT|ROACHNET_BUNDLE_OPENCLAW|ensureBundledNodeRuntime|createBundledSourceArchive/, 'a build can still bundle Node, OpenClaw or RoachNet source')
requirePattern(runtimeSource, /nativeRuntimeBinary\(\)/, 'app launches the native runtime helper')
requirePattern(setupAppSource, /nativeRuntimeBinary\(\)/, 'setup launches the native setup service')
for (const [label, source] of [['app runtime bridge', runtimeSource], ['setup app', setupAppSource], ['repository locator', locatorSource]]) {
  forbidPattern(source, /preferred(?:Portable)?NodeBinary|embeddedNode|ROACHNET_FORCE_NODE_RUNTIME|node-compat|scripts\/run-roachnet-setup\.mjs/, `${label} can still look for or start Node`)
}

if (failures.length > 0) {
  console.error('Native parity audit failed.')
  for (const failure of failures) {
    console.error(`- ${failure}`)
  }
  process.exit(1)
}

console.log('Native parity audit passed.')
