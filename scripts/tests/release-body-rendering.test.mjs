import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { mkdtemp } from 'node:fs/promises'

import {
  bindRenderedReleaseBody,
  createReleaseProvenance,
  createStagedReleaseSnapshot,
  renderStableReleaseBody,
  verifyPublishedRelease,
  verifyRenderedReleaseBody,
} from '../release-provenance.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const notesPath = path.join(repoRoot, 'docs', 'releases', '1.0.6.md')
const notes = readFileSync(notesPath, 'utf8')
const sha256 = (value) => createHash('sha256').update(value).digest('hex')

function fixtureProvenance() {
  return {
    schema: 'org.roachnet.release-provenance.v2',
    candidateSha: 'a'.repeat(40),
    tag: 'v1.0.6',
    version: '1.0.6',
    buildNumber: 106,
    releaseNotes: {
      path: 'docs/releases/1.0.6.md',
      sha256: sha256(notes),
    },
    workflow: {
      runId: 12345,
      runAttempt: 1,
      path: '.github/workflows/native-packages.yml',
      ref: 'RoachWares/RoachNet/.github/workflows/native-packages.yml@refs/tags/v1.0.6',
    },
    artifact: {
      filename: 'RoachNet-Setup-macOS.dmg',
      url: 'https://github.com/RoachWares/RoachNet/releases/download/v1.0.6/RoachNet-Setup-macOS.dmg',
      bytes: 468166812,
      sha256: 'b'.repeat(64),
      checksumUrl: 'https://github.com/RoachWares/RoachNet/releases/download/v1.0.6/RoachNet-Setup-macOS.dmg.sha256',
      checksumFileSha256: 'c'.repeat(64),
    },
    signing: {
      developerIdLabel: 'Developer ID Application: RoachWares LLC (TEAM123456)',
      teamId: 'TEAM123456',
      hardenedRuntime: true,
      timestamped: true,
      verified: true,
    },
    notarization: {
      submissionId: '11111111-2222-3333-4444-555555555555',
      status: 'Accepted',
      stapled: true,
      gatekeeper: 'verified',
    },
    assets: {
      'RoachNet-Setup-macOS.dmg': { bytes: 468166812, sha256: 'b'.repeat(64) },
      'RoachNet-Setup-macOS.dmg.sha256': { bytes: 109, sha256: 'c'.repeat(64) },
      'sbom.spdx.json': { bytes: 200, sha256: 'd'.repeat(64) },
      'binary-license-inventory.json': { bytes: 300, sha256: 'e'.repeat(64) },
      'vulnerability-scan.json': { bytes: 400, sha256: 'f'.repeat(64) },
    },
  }
}

test('stable release body is rendered from tracked notes and exact staged provenance', () => {
  const body = renderStableReleaseBody(notes, fixtureProvenance())

  assert.match(body, /^# RoachNet 1\.0\.6$/m)
  assert.match(body, /Artifact:\n- Download: https:\/\/github\.com\/RoachWares\/RoachNet\/releases\/download\/v1\.0\.6\/RoachNet-Setup-macOS\.dmg/)
  assert.match(body, /- Size: 468166812 bytes/)
  assert.match(body, new RegExp(`- SHA-256: ${'b'.repeat(64)}`))
  assert.match(body, /- Developer ID: Developer ID Application: RoachWares LLC \(TEAM123456\) \(Team TEAM123456\)/)
  assert.match(body, /- Notarization: Accepted; stapled; Gatekeeper verified/)
  assert.match(body, /Windows and Linux desktop installers are not shipped/)
  assert.match(body, /No one-click uninstaller is claimed/)
  assert.doesNotMatch(body, /\{[A-Z0-9_]+\}/)
  assert.doesNotMatch(body, /release candidate|source candidate|RC\/pre-release|draft|No final 1\.0\.6 DMG exists|have not run|not run|must pass Gate|current public-release-surface recheck fails/i)
})

test('rendered body digest binds exact notes and artifact provenance and rejects drift', () => {
  const bound = bindRenderedReleaseBody(notes, fixtureProvenance())

  assert.equal(bound.provenance.renderedReleaseBody.sha256, sha256(bound.body))
  assert.doesNotThrow(() => verifyRenderedReleaseBody(bound.body, notes, bound.provenance))
  assert.throws(
    () => verifyRenderedReleaseBody(bound.body, `${notes}\n`, bound.provenance),
    /release notes do not match staged provenance/i
  )
  assert.throws(
    () => verifyRenderedReleaseBody(bound.body.replace('468166812 bytes', '468166813 bytes'), notes, bound.provenance),
    /rendered release body digest mismatch/i
  )
})

test('staged release snapshot binds exact draft release and asset IDs to provenance', () => {
  const bound = bindRenderedReleaseBody(notes, fixtureProvenance())
  const provenanceText = `${JSON.stringify(bound.provenance, null, 2)}\n`
  const release = {
    id: 9876,
    tag_name: 'v1.0.6',
    draft: true,
    prerelease: true,
    body: notes,
    assets: [
      ...Object.entries(bound.provenance.assets).map(([name, record], index) => ({
        id: 1000 + index,
        name,
        size: record.bytes,
        digest: `sha256:${record.sha256}`,
        browser_download_url: name === bound.provenance.artifact.filename
          ? bound.provenance.artifact.url
          : name === `${bound.provenance.artifact.filename}.sha256`
            ? bound.provenance.artifact.checksumUrl
            : `https://github.com/RoachWares/RoachNet/releases/download/v1.0.6/${name}`,
      })),
      {
        id: 2000,
        name: 'release-provenance.json',
        size: Buffer.byteLength(provenanceText),
        digest: `sha256:${sha256(provenanceText)}`,
        browser_download_url: 'https://github.com/RoachWares/RoachNet/releases/download/v1.0.6/release-provenance.json',
      },
    ],
  }

  const snapshot = createStagedReleaseSnapshot(release, bound.provenance, notes, provenanceText)
  assert.equal(snapshot.releaseId, 9876)
  assert.equal(snapshot.assets.find((asset) => asset.name === 'RoachNet-Setup-macOS.dmg').id, 1000)
  assert.equal(snapshot.provenanceSha256, sha256(provenanceText))
  assert.throws(
    () => createStagedReleaseSnapshot(
      {
        ...release,
        assets: release.assets.map((asset) => asset.name === 'RoachNet-Setup-macOS.dmg'
          ? { ...asset, digest: `sha256:${'0'.repeat(64)}` }
          : asset),
      },
      bound.provenance,
      notes,
      provenanceText
    ),
    /staged release asset identity mismatch/i
  )
})

test('published release readback must retain exact staged IDs, assets, tag, and rendered body', () => {
  const bound = bindRenderedReleaseBody(notes, fixtureProvenance())
  const provenanceText = `${JSON.stringify(bound.provenance, null, 2)}\n`
  const assets = [
    ...Object.entries(bound.provenance.assets).map(([name, record], index) => ({
      id: 1000 + index,
      name,
      size: record.bytes,
      digest: `sha256:${record.sha256}`,
      browser_download_url: `https://github.com/RoachWares/RoachNet/releases/download/v1.0.6/${name}`,
    })),
    {
      id: 2000,
      name: 'release-provenance.json',
      size: Buffer.byteLength(provenanceText),
      digest: `sha256:${sha256(provenanceText)}`,
      browser_download_url: 'https://github.com/RoachWares/RoachNet/releases/download/v1.0.6/release-provenance.json',
    },
  ]
  const staged = { id: 9876, tag_name: 'v1.0.6', draft: true, prerelease: true, body: notes, assets }
  const snapshot = createStagedReleaseSnapshot(staged, bound.provenance, notes, provenanceText)
  const published = {
    ...staged,
    draft: false,
    prerelease: false,
    name: 'RoachNet 1.0.6',
    body: bound.body,
  }

  assert.doesNotThrow(() => verifyPublishedRelease(published, snapshot, bound.provenance, bound.body, '1.0.6'))
  assert.throws(
    () => verifyPublishedRelease(
      { ...published, assets: published.assets.map((asset) => ({ ...asset, id: asset.id + 1 })) },
      snapshot,
      bound.provenance,
      bound.body,
      '1.0.6'
    ),
    /asset set/i
  )
})

test('release provenance is finalized from exact staged files and candidate-specific signing evidence', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachnet-release-provenance-'))
  try {
    const evidenceRoot = path.join(tempRoot, 'release-evidence')
    mkdirSync(evidenceRoot, { recursive: true })
    const files = {
      'RoachNet-Setup-macOS.dmg': 'exact dmg bytes',
      'RoachNet-Setup-macOS.dmg.sha256': 'checksum sidecar bytes',
      'sbom.spdx.json': '{"spdxVersion":"SPDX-2.3"}\n',
      'binary-license-inventory.json': '{"schema":"inventory"}\n',
      'vulnerability-scan.json': '{"schema":"scan"}\n',
    }
    for (const [name, contents] of Object.entries(files)) {
      const target = name.startsWith('RoachNet-') ? path.join(tempRoot, name) : path.join(evidenceRoot, name)
      writeFileSync(target, contents)
    }

    const signingEvidence = {
      schema: 'org.roachnet.release-signing-evidence.v1',
      artifact: 'RoachNet-Setup-macOS.dmg',
      developerIdLabel: 'Developer ID Application: RoachWares LLC (TEAM123456)',
      teamId: 'TEAM123456',
      verified: true,
      hardenedRuntime: true,
      timestamped: true,
      notarization: {
        submissionId: '11111111-2222-3333-4444-555555555555',
        status: 'Accepted',
      },
      stapled: true,
      gatekeeper: 'verified',
    }

    const bound = createReleaseProvenance({
      distPath: tempRoot,
      releaseNotes: notes,
      releaseNotesPath: 'docs/releases/1.0.6.md',
      candidateSha: 'a'.repeat(40),
      tag: 'v1.0.6',
      version: '1.0.6',
      buildNumber: 106,
      repository: 'RoachWares/RoachNet',
      workflowRunId: 12345,
      workflowRunAttempt: 1,
      workflowRef: 'RoachWares/RoachNet/.github/workflows/native-packages.yml@refs/tags/v1.0.6',
      signingEvidence,
    })

    assert.equal(bound.provenance.artifact.bytes, Buffer.byteLength(files['RoachNet-Setup-macOS.dmg']))
    assert.equal(bound.provenance.artifact.sha256, sha256(files['RoachNet-Setup-macOS.dmg']))
    assert.equal(bound.provenance.releaseNotes.sha256, sha256(notes))
    assert.equal(bound.provenance.renderedReleaseBody.sha256, sha256(bound.body))
    assert.deepEqual(Object.keys(bound.provenance.assets).sort(), Object.keys(files).sort())

    assert.throws(
      () => createReleaseProvenance({
        distPath: tempRoot,
        releaseNotes: notes,
        releaseNotesPath: 'docs/releases/1.0.6.md',
        candidateSha: 'a'.repeat(40),
        tag: 'v1.0.6',
        version: '1.0.6',
        buildNumber: 106,
        repository: 'RoachWares/RoachNet',
        workflowRunId: 12345,
        workflowRunAttempt: 1,
        workflowRef: 'RoachWares/RoachNet/.github/workflows/native-packages.yml@refs/tags/v1.0.6',
        signingEvidence: { ...signingEvidence, notarization: { ...signingEvidence.notarization, status: 'Invalid' } },
      }),
      /notarization status is not Accepted/i
    )
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
})
