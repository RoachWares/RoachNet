import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// The promotion audit's offline "verify" pass, on candidates that bundle
// neither runtime (RoachNet 1.1) and ones that bundle Ollama (1.0.x).
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const script = path.join(repoRoot, 'scripts', 'audit-release-supply-chain.mjs')
const sha = (character) => character.repeat(64)

function runAudit({ ollama = 'not-bundled', node = 'not-bundled', results = [] }) {
  const folder = mkdtempSync(path.join(os.tmpdir(), 'rn-supply-chain-'))
  try {
    const component = (name, version) => ({
      name, version, license: 'MIT', source: `https://example.invalid/${name}`,
      ...(version !== 'not-bundled' && ['Node.js', 'Ollama'].includes(name) ? { sourceSha256: sha('c') } : {}),
    })
    writeFileSync(path.join(folder, 'inventory.json'), JSON.stringify({
      schema: 'org.roachnet.release-supply-chain.v1', candidateSha: 'abc123', tag: 'v1.1.1', dmg: { sha256: sha('d') },
      components: [component('RoachNet', '1.1.1'), component('Node.js', node), component('Ollama', ollama), component('OpenClaw', 'not-bundled')],
      files: [{ path: 'RoachNet.app/Contents/MacOS/RoachNet', bytes: 10, sha256: sha('e') }],
    }))
    writeFileSync(path.join(folder, 'sbom.json'), JSON.stringify({ spdxVersion: 'SPDX-2.3' }))
    writeFileSync(path.join(folder, 'vulnerability-scan.json'), JSON.stringify({
      schema: 'org.roachnet.release-vulnerability-scan.v1', candidateSha: 'abc123', tag: 'v1.1.1', scanner: 'OSV API v1/query', results,
    }))
    return spawnSync(process.execPath, [script, '--inventory', path.join(folder, 'inventory.json'), '--sbom', path.join(folder, 'sbom.json'),
      '--candidate-sha', 'abc123', '--tag', 'v1.1.1', '--dmg-sha256', sha('d'), '--online', 'verify'], { encoding: 'utf8' })
  } finally {
    rmSync(folder, { recursive: true, force: true })
  }
}

test('a candidate that bundles no runtime needs no runtime scans', () => {
  const run = runAudit({})
  assert.equal(run.status, 0, run.stderr)
  assert.match(run.stdout, /Release supply-chain audit passed/)
})

test('a bundled runtime still has to be covered by a scan', () => {
  const missing = runAudit({ ollama: '0.40.3' })
  assert.notEqual(missing.status, 0)
  assert.match(missing.stderr, /does not cover every bundled runtime/)
  const covered = runAudit({ ollama: '0.40.3', results: [{ purl: 'pkg:golang/github.com/ollama/ollama@v0.40.3', vulnerabilities: [] }] })
  assert.equal(covered.status, 0, covered.stderr)
})
