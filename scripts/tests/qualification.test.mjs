import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { judgeSkips, readDispositions, skipReport, tapSkips, xctestSkips } from '../lib/test_skips.mjs'
import { checkFixture, readFixtures, tapTotals, xctestTotals } from '../qualify-macos.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const dispositionsFile = path.join(repoRoot, 'docs', 'release-gates', 'qualification-skips.json')

const darwinLog = `
/repo/native/macos/Tests/RoachNetAppTests/RoachMapTilesTests.swift:132: -[RoachNetAppTests.RoachMapTilesTests testFullPackStreetLevelTile] : Test skipped - Set ROACHNET_TEST_MAP_PACK to a state pack
Test Case '-[RoachNetAppTests.RoachMapTilesTests testFullPackStreetLevelTile]' skipped (0.001 seconds).
Test Suite 'RoachNetAppTests.xctest' passed at 2026-10-13 22:21:12.458.
\t Executed 141 tests, with 1 test skipped and 0 failures (0 unexpected) in 45.163 (45.173) seconds
Test Suite 'RoachInferenceTests.xctest' failed at 2026-10-13 22:27:07.730.
\t Executed 40 tests, with 2 failures (0 unexpected) in 354.374 (354.381) seconds
`
const linuxLog = `
/repo/native/macos/Tests/RoachNetRuntimeTests/HTTPClientLimitTests.swift:39: HTTPClientLimitTests.testEndlessBodyStopsAtTheLimitInsteadOfBufferingFirst : Test skipped: required true value but got false - Linux: the size limit can trip late (ROA-87)
/repo/native/macos/Tests/RoachInferenceTests/MetalParityTests.swift:45: MetalParityTests.testMetalMatchesCPUOnReferenceModels : Test skipped - Metal is not available on this platform.
`
const tap = `
ok 1 - top level test
ok 2 - a skipped test # SKIP needs ditto
    ok 1 - a nested skip # SKIP nested reason
ok 3 - skipped without a reason # SKIP
# tests 4
# pass 1
# fail 0
# skipped 3
`

test('skips are read from macOS and Linux XCTest output and from TAP', () => {
  assert.deepEqual(xctestSkips(darwinLog), [
    { id: 'RoachMapTilesTests.testFullPackStreetLevelTile', reason: 'Set ROACHNET_TEST_MAP_PACK to a state pack', kind: 'xctest' },
  ])
  assert.deepEqual(xctestSkips(linuxLog).map((skip) => skip.id), [
    'HTTPClientLimitTests.testEndlessBodyStopsAtTheLimitInsteadOfBufferingFirst',
    'MetalParityTests.testMetalMatchesCPUOnReferenceModels',
  ])
  assert.match(xctestSkips(linuxLog)[0].reason, /ROA-87/)
  assert.deepEqual(tapSkips(tap), [
    { id: 'a skipped test', reason: 'needs ditto', kind: 'tap' },
    { id: 'a nested skip', reason: 'nested reason', kind: 'tap' },
    { id: 'skipped without a reason', reason: '', kind: 'tap' },
  ])
  assert.deepEqual(xctestTotals(darwinLog), [
    { bundle: 'RoachNetAppTests', result: 'passed', tests: 141, skipped: 1, failures: 0 },
    { bundle: 'RoachInferenceTests', result: 'failed', tests: 40, skipped: 0, failures: 2 },
  ])
  assert.deepEqual(tapTotals(tap), { tests: 4, pass: 1, fail: 0, skipped: 3 })
})

test('a qualification run allows only skips of tests that cannot run on the platform', () => {
  const dispositions = [
    { kind: 'tap', id: 'hydration', platforms: ['macos'], scope: 'always', why: 'no Core ML on Linux', disposition: 'runs on Linux' },
    { kind: 'xctest', id: 'Metal.parity', platforms: ['macos'], scope: 'ci', why: 'needs the models', disposition: 'runs in qualification' },
  ]
  const skips = [
    { kind: 'tap', id: 'hydration', reason: '' },
    { kind: 'xctest', id: 'Metal.parity', reason: 'Set ROACHNET_TEST_MODELS' },
    { kind: 'xctest', id: 'Unknown.test', reason: 'whatever' },
  ]
  const qualification = judgeSkips(skips, dispositions, 'macos', 'qualification')
  assert.deepEqual(qualification.allowed.map((skip) => skip.id), ['hydration'])
  assert.deepEqual(qualification.unrecorded.map((skip) => skip.id), ['Metal.parity', 'Unknown.test'])
  const ci = judgeSkips(skips, dispositions, 'macos', 'ci')
  assert.deepEqual(ci.allowed.map((skip) => skip.id), ['hydration', 'Metal.parity'])
  assert.deepEqual(ci.unrecorded.map((skip) => skip.id), ['Unknown.test'])
  // A disposition for one platform doesn't cover another.
  assert.equal(judgeSkips(skips, dispositions, 'linux', 'ci').allowed.length, 0)
  assert.throws(() => judgeSkips(skips, dispositions, 'windows'), /unknown platform/)

  // Table cells stay one cell whatever a name holds.
  const report = skipReport({ allowed: [], unrecorded: [{ kind: 'tap', id: 'a \\| b | c', reason: 'line one\nline two' }] }, 'macos')
  const row = report.split('\n').find((line) => line.startsWith('| a'))
  assert.equal(row, '| a \\\\\\| b \\| c | line one line two |')
})

test('the recorded dispositions are complete and unambiguous', () => {
  const entries = readDispositions(dispositionsFile)
  const seen = new Set()
  for (const entry of entries) {
    for (const platform of entry.platforms) {
      const key = `${platform}|${entry.kind}|${entry.id}`
      assert.ok(!seen.has(key), `${key} is recorded twice`)
      seen.add(key)
    }
  }
  // On a Mac with the fixtures, only the Linux-path hydration test may skip.
  const macAlways = entries.filter((entry) => entry.platforms.includes('macos') && entry.scope === 'always').map((entry) => entry.id)
  assert.deepEqual(macAlways, ['RoachVoice hydration fails clearly before any download when Core ML tooling is unavailable'])
  // The Metal GPU parity tests may skip in macOS CI, never in a macOS qualification.
  for (const entry of entries.filter((item) => item.id.startsWith('MetalParityTests.') && item.platforms.includes('macos'))) {
    assert.equal(entry.scope, 'ci', entry.id)
  }

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rn-skips-'))
  try {
    const bad = path.join(dir, 'bad.json')
    fs.writeFileSync(bad, JSON.stringify({ schema: 'org.roachnet.qualification-skips.v1', skips: [{ kind: 'tap', id: 'x', platforms: ['macos'], scope: 'sometimes', why: 'long enough why', disposition: 'long enough disposition' }] }))
    assert.throws(() => readDispositions(bad), /scope must be/)
    fs.writeFileSync(bad, JSON.stringify({ schema: 'org.roachnet.qualification-skips.v1', skips: [{ kind: 'tap', id: 'x', platforms: ['macos'], scope: 'ci', why: 'ok?', disposition: 'long enough disposition' }] }))
    assert.throws(() => readDispositions(bad), /needs a why/)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('check-test-skips fails a strict run on an unrecorded skip and writes the summary', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rn-skips-'))
  try {
    const log = path.join(dir, 'xctest.log')
    const summary = path.join(dir, 'summary.md')
    fs.writeFileSync(log, darwinLog)
    const script = path.join(repoRoot, 'scripts', 'check-test-skips.mjs')
    const strict = spawnSync(process.execPath, [script, '--platform', 'macos', '--mode', 'qualification', '--xctest', log, '--strict', '--summary', summary], { encoding: 'utf8', env: { ...process.env, GITHUB_ACTIONS: '' } })
    assert.equal(strict.status, 1, strict.stdout + strict.stderr)
    assert.match(fs.readFileSync(summary, 'utf8'), /RoachMapTilesTests\.testFullPackStreetLevelTile/)
    const ci = spawnSync(process.execPath, [script, '--platform', 'macos', '--mode', 'ci', '--xctest', log, '--strict'], { encoding: 'utf8' })
    assert.equal(ci.status, 0, ci.stdout + ci.stderr)
    const usage = spawnSync(process.execPath, [script, '--xctest', log], { encoding: 'utf8' })
    assert.equal(usage.status, 2)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('qualification fixtures are pinned, and a file is used only when its bytes match', () => {
  const fixtures = readFixtures()
  assert.deepEqual(new Set(fixtures.map((item) => item.file)).size, fixtures.length, 'file names are unique')
  for (const item of fixtures) {
    assert.match(item.url, /^https:\/\//, item.file)
    assert.ok(/\/resolve\/[0-9a-f]{40}\//.test(item.url) || /\/v\d+\.\d+\.\d+\//.test(item.url) || /\/releases\/download\/[^/]+\//.test(item.url), `${item.file} is pinned: ${item.url}`)
    assert.match(item.sha256, /^[0-9a-f]{64}$/, item.file)
    assert.ok(Number.isSafeInteger(item.bytes) && item.bytes > 0, item.file)
  }
  // The model files the model-backed tests open by name.
  for (const name of ['stories15M-q4_0', 'smollm2-135m-q8_0', 'qwen2.5-0.5b-q4_k_m', 'qwen3-0.6b-q8_0']) {
    assert.ok(fixtures.some((item) => item.folder === 'models' && item.file === `${name}.gguf`), name)
  }

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rn-fixture-'))
  try {
    const bytes = Buffer.from('pinned fixture bytes\n')
    const expected = { bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }
    const file = path.join(dir, 'fixture.bin')
    assert.equal(checkFixture(file, expected), 'missing')
    fs.writeFileSync(file, bytes)
    assert.equal(checkFixture(file, expected), 'ok')
    fs.writeFileSync(file, Buffer.alloc(bytes.length, 0x41))
    assert.match(checkFixture(file, expected), /^SHA-256 /)
    fs.writeFileSync(file, Buffer.concat([bytes, bytes]))
    assert.match(checkFixture(file, expected), /bytes, expected/)
    const link = path.join(dir, 'link.bin')
    fs.writeFileSync(file, bytes)
    fs.symlinkSync(file, link)
    assert.equal(checkFixture(link, expected), 'not a regular file')
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
