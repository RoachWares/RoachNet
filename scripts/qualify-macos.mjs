#!/usr/bin/env node
// The macOS qualification run: every test, with every model and fixture it
// needs, and no skip that hasn't been accounted for.
//
//   node scripts/qualify-macos.mjs [--fixtures DIR] [--fetch] [--out DIR] [--skip-build]
//
// 1. Checks the pinned fixtures in docs/release-gates/qualification-fixtures.json
//    by size and SHA-256. --fetch downloads a missing one and verifies it
//    before use. A file that doesn't match is never used.
// 2. Checks that the RoachWhisper Core ML pack is staged and matches its
//    recorded upstream digests (node scripts/prepare-roachspeech-release-packs.mjs
//    stages it).
// 3. Builds, runs the XCTests with the models, the Whisper sample and the
//    state map pack, then runs the contract tests with the built runtime and
//    roachnet-infer.
// 4. Fails on any test failure, and on any skip that
//    docs/release-gates/qualification-skips.json doesn't allow in a
//    qualification run.
// Logs and summary.json go to --out (default .tmp/qualification/<UTC time>).

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { checkSkips } from './check-test-skips.mjs'
import { verifyImportedUpstreamFiles } from './lib/roachspeech_pack_digests.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
export const fixturesManifestPath = path.join(repoRoot, 'docs', 'release-gates', 'qualification-fixtures.json')
const whisperPack = 'roachwhisper-openai-whisper-base-en-coreml'
const packsRoot = path.join(repoRoot, 'native', 'macos', 'Vendor', 'RoachSpeech', 'ModelPacks')

export function readFixtures(file = fixturesManifestPath) {
  const manifest = JSON.parse(fs.readFileSync(file, 'utf8'))
  if (manifest.schema !== 'org.roachnet.qualification-fixtures.v1') throw new Error(`${file} has an unknown schema`)
  return [
    ...manifest.models.map((item) => ({ ...item, folder: 'models' })),
    ...manifest.files.map((item) => ({ ...item, folder: 'files' })),
  ]
}

function sha256(file) {
  const hash = createHash('sha256')
  const fd = fs.openSync(file, 'r')
  try {
    const buffer = Buffer.allocUnsafe(1 << 20)
    for (let read; (read = fs.readSync(fd, buffer, 0, buffer.length, null)) > 0;) hash.update(buffer.subarray(0, read))
  } finally {
    fs.closeSync(fd)
  }
  return hash.digest('hex')
}

/** 'ok', 'missing', or why the file at `file` isn't the pinned one. */
export function checkFixture(file, { bytes, sha256: expected }) {
  let info
  try {
    info = fs.lstatSync(file)
  } catch {
    return 'missing'
  }
  if (!info.isFile()) return 'not a regular file'
  if (info.size !== bytes) return `${info.size} bytes, expected ${bytes}`
  const digest = sha256(file)
  return digest === expected ? 'ok' : `SHA-256 ${digest}, expected ${expected}`
}

function fetchFixture(file, item) {
  const partial = `${file}.partial-${process.pid}`
  fs.mkdirSync(path.dirname(file), { recursive: true })
  try {
    const result = spawnSync('curl', ['--fail', '--silent', '--show-error', '--location', '--retry', '5', '--retry-all-errors',
      '--retry-max-time', '300', '--output', partial, item.url], { stdio: ['ignore', 'inherit', 'inherit'] })
    if (result.status !== 0) return `download failed (curl ${result.status ?? result.signal})`
    const verdict = checkFixture(partial, item)
    if (verdict !== 'ok') return `downloaded file doesn't match: ${verdict}`
    fs.renameSync(partial, file)
    return 'ok'
  } finally {
    fs.rmSync(partial, { force: true })
  }
}

/** Per-bundle totals from `swift test` output. */
export function xctestTotals(text) {
  const bundles = []
  const lines = text.split(/\r?\n/)
  for (let index = 0; index < lines.length; index += 1) {
    const suite = /^Test Suite '([^']+)\.xctest' (passed|failed)/.exec(lines[index])
    if (!suite) continue
    const executed = /Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?/.exec(lines[index + 1] ?? '')
    if (executed && !bundles.some((bundle) => bundle.bundle === suite[1])) {
      bundles.push({ bundle: suite[1], result: suite[2], tests: Number(executed[1]), skipped: Number(executed[2] ?? 0), failures: Number(executed[3]) })
    }
  }
  return bundles
}

/** The closing counts of a node:test TAP stream. */
export function tapTotals(text) {
  const totals = {}
  for (const match of text.matchAll(/^# (tests|pass|fail|skipped|cancelled|todo) (\d+)$/gm)) totals[match[1]] = Number(match[2])
  return totals
}

function run(command, args, { env = process.env, log, cwd = repoRoot } = {}) {
  const fd = fs.openSync(log, 'w')
  try {
    const result = spawnSync(command, args, { cwd, env, stdio: ['ignore', fd, fd], maxBuffer: 1 << 30 })
    return result.status ?? 1
  } finally {
    fs.closeSync(fd)
  }
}

function capture(command, args) {
  const result = spawnSync(command, args, { cwd: repoRoot, encoding: 'utf8' })
  return result.status === 0 ? result.stdout.trim() : null
}

function parseArgs(argv) {
  const args = { fetch: false, skipBuild: false }
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    const value = () => {
      const next = argv[++index]
      if (!next) throw new Error(`${flag} needs a value`)
      return next
    }
    if (flag === '--fixtures') args.fixtures = path.resolve(value())
    else if (flag === '--out') args.out = path.resolve(value())
    else if (flag === '--fetch') args.fetch = true
    else if (flag === '--skip-build') args.skipBuild = true
    else throw new Error(`unknown option ${flag}`)
  }
  args.fixtures ??= path.join(repoRoot, '.tmp', 'qualification-fixtures')
  args.out ??= path.join(repoRoot, '.tmp', 'qualification', new Date().toISOString().replace(/[:.]/g, '-'))
  return args
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    throw new Error('The macOS qualification needs an Apple-silicon Mac: the Metal parity tests run on its GPU.')
  }
  fs.mkdirSync(args.out, { recursive: true })
  const summary = {
    schema: 'org.roachnet.qualification-run.v1',
    started: new Date().toISOString(),
    commit: capture('git', ['rev-parse', 'HEAD']),
    tree: capture('git', ['rev-parse', 'HEAD^{tree}']),
    uncommittedFiles: (capture('git', ['status', '--porcelain', '--untracked-files=no']) ?? '').split('\n').filter(Boolean).length,
    macOS: capture('sw_vers', ['-productVersion']),
    swift: capture('xcrun', ['swift', '--version'])?.split('\n')[0] ?? null,
    node: process.version,
    cpus: os.cpus().length,
    failures: [],
  }

  // 1. Pinned fixtures.
  const env = { ...process.env }
  summary.fixtures = []
  for (const item of readFixtures()) {
    const file = path.join(args.fixtures, item.folder, item.file)
    let verdict = checkFixture(file, item)
    if (verdict !== 'ok' && args.fetch) {
      console.log(`Fetching ${item.file} (${verdict})`)
      fs.rmSync(file, { force: true })
      verdict = fetchFixture(file, item)
    }
    summary.fixtures.push({ file: item.file, sha256: item.sha256, verdict })
    if (verdict !== 'ok') summary.failures.push(`fixture ${item.file}: ${verdict}${args.fetch ? '' : ' (run with --fetch to download it)'}`)
    if (item.env) env[item.env] = file
  }
  env.ROACHNET_TEST_MODELS = path.join(args.fixtures, 'models')

  // 2. The staged RoachWhisper pack.
  try {
    const checked = await verifyImportedUpstreamFiles(path.join(repoRoot, 'docs', 'release-gates', 'roachspeech-pack-digests.json'),
      whisperPack, path.join(packsRoot, whisperPack))
    summary.whisperPack = `${checked} upstream files match`
    if (!checked) summary.failures.push(`${whisperPack} isn't recorded in roachspeech-pack-digests.json`)
  } catch (error) {
    summary.whisperPack = error.message.split('\n')[0]
    summary.failures.push(`${whisperPack}: ${summary.whisperPack} (stage it with node scripts/prepare-roachspeech-release-packs.mjs)`)
  }
  if (summary.failures.length) return finish(summary, args)

  // 3. Build and test.
  if (!args.skipBuild) {
    summary.build = run('xcrun', ['swift', 'build', '--package-path', 'native/macos', '--build-tests'], { log: path.join(args.out, 'build.log') })
    if (summary.build !== 0) {
      summary.failures.push('the build failed (see build.log)')
      return finish(summary, args)
    }
  }
  const xctestLog = path.join(args.out, 'xctest.log')
  summary.xctestExit = run('xcrun', ['swift', 'test', '--package-path', 'native/macos', '--skip-build'], { env, log: xctestLog })
  summary.xctest = xctestTotals(fs.readFileSync(xctestLog, 'utf8'))
  if (summary.xctestExit !== 0) summary.failures.push('XCTests failed (see xctest.log)')
  if (!summary.xctest.length) summary.failures.push('no XCTest results were found in xctest.log')

  const debug = path.join(repoRoot, 'native', 'macos', '.build', 'debug')
  const testEnv = { ...env, ROACHNET_NATIVE_API_BINARY: path.join(debug, 'roachnet-runtime'), ROACHNET_INFERENCE_TOOL: path.join(debug, 'roachnet-infer') }
  const tests = fs.readdirSync(path.join(repoRoot, 'scripts', 'tests')).filter((name) => name.endsWith('.test.mjs')).sort()
    .map((name) => path.join('scripts', 'tests', name))
  const tap = path.join(args.out, 'contract.tap')
  summary.contractExit = run(process.execPath, ['--test', '--test-reporter=tap', ...tests], { env: testEnv, log: tap })
  summary.contract = tapTotals(fs.readFileSync(tap, 'utf8'))
  if (summary.contractExit !== 0) summary.failures.push('contract tests failed (see contract.tap)')

  // 4. Skips.
  const skips = checkSkips({ platform: 'macos', mode: 'qualification', xctest: [xctestLog], tap: [tap], strict: true })
  fs.writeFileSync(path.join(args.out, 'skips.md'), `${skips.report}\n`)
  summary.skips = { allowed: skips.allowed, unrecorded: skips.unrecorded }
  if (!skips.ok) summary.failures.push(`${skips.unrecorded.length} test(s) skipped without a disposition that allows it (see skips.md)`)
  return finish(summary, args)
}

function finish(summary, args) {
  summary.finished = new Date().toISOString()
  summary.result = summary.failures.length ? 'FAIL' : 'PASS'
  fs.writeFileSync(path.join(args.out, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`)
  console.log(`Qualification ${summary.result} at ${summary.commit ?? 'unknown commit'} (tree ${summary.tree ?? '?'})`)
  for (const bundle of summary.xctest ?? []) {
    console.log(`  ${bundle.bundle}: ${bundle.tests} tests, ${bundle.skipped} skipped, ${bundle.failures} failures (${bundle.result})`)
  }
  if (summary.contract) {
    const { tests, pass, fail, skipped } = summary.contract
    console.log(`  contract tests: ${tests} tests, ${pass} pass, ${fail} fail, ${skipped} skipped`)
  }
  for (const failure of summary.failures) console.log(`  FAIL: ${failure}`)
  const relative = path.relative(repoRoot, args.out)
  console.log(`  logs: ${relative && !relative.startsWith('..') ? relative : args.out}`)
  process.exitCode = summary.failures.length ? 1 : 0
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error)
    process.exitCode = 2
  })
}
