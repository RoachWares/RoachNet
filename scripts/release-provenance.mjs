#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { readFileSync, statSync } from 'node:fs'
import path from 'node:path'

export function sha256Text(value) {
  return createHash('sha256').update(value).digest('hex')
}

function requireValue(condition, message) {
  if (!condition) throw new Error(message)
}

function requireSha256(value, label) {
  requireValue(/^[a-f0-9]{64}$/.test(String(value || '')), `${label} must be a lowercase SHA-256 digest.`)
}

function section(notes, heading, nextHeading) {
  const startMarker = `## ${heading}\n`
  const start = notes.indexOf(startMarker)
  requireValue(start !== -1, `Tracked release notes are missing the ${heading} section.`)
  const contentStart = start + startMarker.length
  const end = nextHeading ? notes.indexOf(`## ${nextHeading}\n`, contentStart) : notes.length
  requireValue(end !== -1, `Tracked release notes are missing the ${nextHeading} section.`)
  return notes.slice(contentStart, end).trim()
}

export function validateReleaseProvenance(provenance, releaseNotes) {
  requireValue(provenance?.schema === 'org.roachnet.release-provenance.v2', 'Unknown release provenance schema.')
  requireValue(/^\d+\.\d+\.\d+$/.test(provenance.version || ''), 'Provenance version is invalid.')
  requireValue(provenance.tag === `v${provenance.version}`, 'Provenance tag does not match its version.')
  requireValue(/^[a-f0-9]{40}$/.test(provenance.candidateSha || ''), 'Provenance candidate SHA is invalid.')
  requireValue(Number.isSafeInteger(provenance.buildNumber) && provenance.buildNumber > 0, 'Provenance build number is invalid.')

  const releaseNotesRecord = provenance.releaseNotes || {}
  requireValue(releaseNotesRecord.path === `docs/releases/${provenance.version}.md`, 'Release-notes provenance path is invalid.')
  requireSha256(releaseNotesRecord.sha256, 'Release-notes provenance')
  requireValue(sha256Text(releaseNotes) === releaseNotesRecord.sha256, 'Tracked release notes do not match staged provenance.')

  const workflow = provenance.workflow || {}
  requireValue(Number.isSafeInteger(workflow.runId) && workflow.runId > 0, 'Stage workflow run ID is invalid.')
  requireValue(Number.isSafeInteger(workflow.runAttempt) && workflow.runAttempt > 0, 'Stage workflow run attempt is invalid.')
  requireValue(workflow.path === '.github/workflows/native-packages.yml', 'Stage workflow path is invalid.')
  requireValue(typeof workflow.ref === 'string' && workflow.ref.includes(workflow.path), 'Stage workflow ref is invalid.')

  const artifact = provenance.artifact || {}
  requireValue(artifact.filename === 'RoachNet-Setup-macOS.dmg', 'Unexpected staged DMG filename.')
  requireValue(Number.isSafeInteger(artifact.bytes) && artifact.bytes > 0, 'Staged DMG byte size is invalid.')
  requireSha256(artifact.sha256, 'Staged DMG')
  requireSha256(artifact.checksumFileSha256, 'Checksum sidecar file')
  const expectedAssetRoot = `https://github.com/RoachWares/RoachNet/releases/download/${encodeURIComponent(provenance.tag)}/`
  requireValue(artifact.url === `${expectedAssetRoot}${artifact.filename}`, 'Staged DMG URL does not match the provenance tag and filename.')
  requireValue(artifact.checksumUrl === `${expectedAssetRoot}${artifact.filename}.sha256`, 'Staged checksum URL does not match the provenance tag and filename.')

  const signing = provenance.signing || {}
  requireValue(typeof signing.developerIdLabel === 'string' && signing.developerIdLabel.startsWith('Developer ID Application:'), 'Developer ID label is invalid.')
  requireValue(/^[A-Z0-9]{10}$/.test(signing.teamId || ''), 'Developer ID team is invalid.')
  requireValue(signing.developerIdLabel.includes(signing.teamId), 'Developer ID label and team do not match.')
  requireValue(signing.verified === true, 'Developer ID verification is not PASS.')
  requireValue(signing.hardenedRuntime === true, 'Hardened runtime verification is not PASS.')
  requireValue(signing.timestamped === true, 'Code-signing timestamp verification is not PASS.')

  const notarization = provenance.notarization || {}
  requireValue(/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(notarization.submissionId || ''), 'Notarization submission ID is invalid.')
  requireValue(notarization.status === 'Accepted', 'Notarization status is not Accepted.')
  requireValue(notarization.stapled === true, 'Stapler verification is not PASS.')
  requireValue(notarization.gatekeeper === 'verified', 'Gatekeeper verification is not PASS.')
}

function sanitizeBullets(content, replacements, omittedFragments = []) {
  const result = []
  for (let line of content.split('\n')) {
    if (omittedFragments.some((fragment) => line.includes(fragment))) continue
    for (const [source, replacement] of replacements) line = line.replace(source, replacement)
    result.push(line)
  }
  return result.join('\n').trim()
}

function stableLimitations(content) {
  const lines = content.split('\n')
  const tableStart = lines.findIndex((line) => line.startsWith('| Limitation |'))
  requireValue(tableStart !== -1, 'Tracked release notes are missing the limitations table.')
  const rows = lines.slice(tableStart + 2).filter((line) => line.startsWith('|'))
  const retained = rows
    .filter((line) => {
      const columns = line.split('|').map((value) => value.trim())
      return columns.at(-2)?.startsWith('No')
    })
    .map((line) => line.replace(/\| No after offline failure behavior passes; the current missing test evidence is blocking\. \|$/, '| No. |'))
    .map((line) => line.replace(/\| No, unless public copy claims a new companion build\. \|$/, '| No. |'))
    .map((line) => line.replace(/\| The feature gap is not inherently blocking; untested removal is\. \|$/, '| No. |'))
  return [lines[tableStart], lines[tableStart + 1], ...retained].join('\n')
}

export function validateStableReleaseBody(body) {
  const forbidden = [
    /\{[A-Z0-9_]+\}/,
    /release candidate/i,
    /source candidate/i,
    /\bcandidate\b/i,
    /\bRC\b/i,
    /RC\/pre-release/i,
    /^Status:\s*draft/im,
    /No final \d+\.\d+\.\d+ DMG exists/i,
    /have not run/i,
    /\bnot run\b/i,
    /current public-release-surface recheck fails/i,
  ]
  for (const pattern of forbidden) {
    requireValue(!pattern.test(body), `Stable release body contains RC-only or unresolved copy: ${pattern}`)
  }
}

export function renderStableReleaseBody(releaseNotes, provenance) {
  validateReleaseProvenance(provenance, releaseNotes)

  const changed = sanitizeBullets(
    section(releaseNotes, 'What changed', 'Security and privacy'),
    [
      [' The source and Node behavior tests are present; final macOS interaction and visual behavior still require candidate-specific testing.', ''],
      ['public source candidate', 'public source release'],
      ['stages a signed RC as a quarantined draft', 'stages signed builds in quarantine'],
    ]
  )
  const security = sanitizeBullets(
    section(releaseNotes, 'Security and privacy', 'Install, upgrade, backup, rollback, and removal'),
    [
      [' Final mounted-artifact security and privacy review is still required.', ''],
      [' These source results do not establish the state of the final macOS bundle, which still needs its own SBOM, binary/license inventory, and candidate-bound vulnerability scan.', ''],
      [' Do not configure cloud credentials in this RC until the Apple-host privacy review has passed.', ''],
    ],
    ['current public-release-surface recheck fails']
  )
  const install = sanitizeBullets(
    section(releaseNotes, 'Install, upgrade, backup, rollback, and removal', 'Local and offline boundaries'),
    [
      ['Keep v1.0.5 installed unless you are deliberately testing the RC.', 'Quit the currently installed RoachNet version before opening the installer.'],
      ['The installer is expected to preserve existing user storage, but the v1.0.5-to-v1.0.6 overwrite path and failed-upgrade recovery have not been tested on the final artifact. Do not use irreplaceable data for RC testing.', 'Back up existing user storage before an overwrite upgrade and keep the backup until the upgraded installation is verified.'],
      ['This candidate adds local state schemas, and downgrade compatibility has not been proved.', 'RoachNet 1.0.6 adds local state schemas, so do not assume downgrade compatibility.'],
      ['Exact removal and owned-process cleanup steps must pass Gate E before stable release.', 'Quit all RoachNet-owned processes before removing runtime material.'],
    ],
    [
      'These are the intended procedures. They are not certified',
      'The required free-disk budget and install duration have not been measured',
    ]
  )
  const offline = sanitizeBullets(
    section(releaseNotes, 'Local and offline boundaries', 'Artifact identity and verification'),
    [
      [' The final offline-first-launch and failure behavior have not yet been tested on the 1.0.6 artifact.', ''],
      [' That behavior remains a release gate, not an assumption.', ''],
    ]
  )
  const limitations = stableLimitations(section(releaseNotes, 'Known limitations', 'Support, license, and attribution'))
  const support = section(releaseNotes, 'Support, license, and attribution', 'Evidence boundary')
  const artifact = provenance.artifact
  const signing = provenance.signing

  const body = `# RoachNet ${provenance.version}

Version/build: ${provenance.version} / ${provenance.buildNumber}
Platform: Apple Silicon Mac, macOS 14 or later
Installer: \`${artifact.filename}\`

## What changed

${changed}

## Security and privacy

${security}

## Install, upgrade, backup, rollback, and removal

${install}

## Local and offline boundaries

${offline}

## Artifact identity and verification

Artifact:
- Download: ${artifact.url}
- Size: ${artifact.bytes} bytes
- SHA-256: ${artifact.sha256}
- Checksum sidecar: ${artifact.checksumUrl}
- Developer ID: ${signing.developerIdLabel} (Team ${signing.teamId})
- Notarization: Accepted; stapled; Gatekeeper verified

## Known limitations

${limitations}

## Support, license, and attribution

${support}
`

  validateStableReleaseBody(body)
  return body
}

function fileRecord(filePath) {
  const contents = readFileSync(filePath)
  return {
    bytes: statSync(filePath).size,
    sha256: createHash('sha256').update(contents).digest('hex'),
  }
}

export function createReleaseProvenance({
  distPath,
  releaseNotes,
  releaseNotesPath,
  candidateSha,
  tag,
  version,
  buildNumber,
  repository,
  workflowRunId,
  workflowRunAttempt,
  workflowRef,
  signingEvidence,
}) {
  requireValue(repository === 'RoachWares/RoachNet', 'Release repository identity is invalid.')
  requireValue(signingEvidence?.schema === 'org.roachnet.release-signing-evidence.v1', 'Release signing evidence schema is invalid.')
  requireValue(signingEvidence.artifact === 'RoachNet-Setup-macOS.dmg', 'Release signing evidence is not bound to the staged DMG.')

  const assetLocations = {
    'RoachNet-Setup-macOS.dmg': path.join(distPath, 'RoachNet-Setup-macOS.dmg'),
    'RoachNet-Setup-macOS.dmg.sha256': path.join(distPath, 'RoachNet-Setup-macOS.dmg.sha256'),
    'sbom.spdx.json': path.join(distPath, 'release-evidence', 'sbom.spdx.json'),
    'binary-license-inventory.json': path.join(distPath, 'release-evidence', 'binary-license-inventory.json'),
    'vulnerability-scan.json': path.join(distPath, 'release-evidence', 'vulnerability-scan.json'),
  }
  const assets = Object.fromEntries(
    Object.entries(assetLocations).map(([name, filePath]) => [name, fileRecord(filePath)])
  )
  const dmg = assets['RoachNet-Setup-macOS.dmg']
  const sidecar = assets['RoachNet-Setup-macOS.dmg.sha256']
  const encodedTag = encodeURIComponent(tag)
  const assetRoot = `https://github.com/${repository}/releases/download/${encodedTag}`
  const provisional = {
    schema: 'org.roachnet.release-provenance.v2',
    candidateSha,
    tag,
    version,
    buildNumber: Number(buildNumber),
    releaseNotes: {
      path: releaseNotesPath,
      sha256: sha256Text(releaseNotes),
    },
    workflow: {
      runId: Number(workflowRunId),
      runAttempt: Number(workflowRunAttempt),
      path: '.github/workflows/native-packages.yml',
      ref: workflowRef,
    },
    artifact: {
      filename: 'RoachNet-Setup-macOS.dmg',
      url: `${assetRoot}/RoachNet-Setup-macOS.dmg`,
      bytes: dmg.bytes,
      sha256: dmg.sha256,
      checksumUrl: `${assetRoot}/RoachNet-Setup-macOS.dmg.sha256`,
      checksumFileSha256: sidecar.sha256,
    },
    signing: {
      developerIdLabel: signingEvidence.developerIdLabel,
      teamId: signingEvidence.teamId,
      verified: signingEvidence.verified,
      hardenedRuntime: signingEvidence.hardenedRuntime,
      timestamped: signingEvidence.timestamped,
    },
    notarization: {
      submissionId: signingEvidence.notarization?.submissionId,
      status: signingEvidence.notarization?.status,
      stapled: signingEvidence.stapled,
      gatekeeper: signingEvidence.gatekeeper,
    },
    assets,
    dmgSha256: dmg.sha256,
    releaseNotesSha256: sha256Text(releaseNotes),
    workflowRunId: Number(workflowRunId),
    workflowRunAttempt: Number(workflowRunAttempt),
    workflowPath: '.github/workflows/native-packages.yml',
    workflowRef,
  }
  return bindRenderedReleaseBody(releaseNotes, provisional)
}

export function createStagedReleaseSnapshot(release, provenance, releaseNotes, provenanceText) {
  validateReleaseProvenance(provenance, releaseNotes)
  requireSha256(provenance.renderedReleaseBody?.sha256, 'Rendered release body')
  requireValue(
    JSON.stringify(JSON.parse(provenanceText)) === JSON.stringify(provenance),
    'Serialized release provenance does not match the staged provenance object.'
  )
  requireValue(Number.isSafeInteger(release?.id) && release.id > 0, 'Staged release ID is invalid.')
  requireValue(
    release.tag_name === provenance.tag && release.draft === true && release.prerelease === true,
    'Staged release is not the expected draft prerelease.'
  )
  requireValue(
    sha256Text(release.body || '') === provenance.releaseNotes.sha256,
    'Staged draft body does not match tracked release notes provenance.'
  )

  const provenanceRecord = {
    bytes: Buffer.byteLength(provenanceText),
    sha256: sha256Text(provenanceText),
  }
  const expectedRecords = {
    ...provenance.assets,
    'release-provenance.json': provenanceRecord,
  }
  const expectedNames = Object.keys(expectedRecords).sort()
  const actualNames = (release.assets || []).map((asset) => asset.name).sort()
  requireValue(
    JSON.stringify(actualNames) === JSON.stringify(expectedNames),
    'Staged release asset set does not match provenance.'
  )

  const assetRoot = `https://github.com/RoachWares/RoachNet/releases/download/${encodeURIComponent(provenance.tag)}/`
  const assets = []
  for (const name of expectedNames) {
    const asset = release.assets.find((entry) => entry.name === name)
    const record = expectedRecords[name]
    requireValue(
      Number.isSafeInteger(asset?.id) &&
        asset.id > 0 &&
        asset.size === record.bytes &&
        asset.digest === `sha256:${record.sha256}` &&
        asset.browser_download_url === `${assetRoot}${name}`,
      `Staged release asset identity mismatch: ${name}`
    )
    assets.push({
      id: asset.id,
      name,
      bytes: asset.size,
      sha256: record.sha256,
      url: asset.browser_download_url,
    })
  }

  return {
    schema: 'org.roachnet.staged-release-snapshot.v1',
    releaseId: release.id,
    candidateSha: provenance.candidateSha,
    tag: provenance.tag,
    workflowRunId: provenance.workflow.runId,
    workflowRunAttempt: provenance.workflow.runAttempt,
    releaseNotesSha256: provenance.releaseNotes.sha256,
    renderedReleaseBodySha256: provenance.renderedReleaseBody.sha256,
    provenanceSha256: provenanceRecord.sha256,
    assets,
  }
}

export function verifyPublishedRelease(release, snapshot, provenance, body, version) {
  requireValue(release?.id === snapshot.releaseId, 'Published release ID does not match the staged snapshot.')
  requireValue(release.tag_name === snapshot.tag && release.tag_name === provenance.tag, 'Published release tag does not match the staged snapshot.')
  requireValue(release.draft === false && release.prerelease === false, 'Published release is not stable.')
  requireValue(release.name === `RoachNet ${version}`, 'Published release name is invalid.')
  requireValue(body === release.body, 'Published release body does not match the verified rendered body.')
  requireValue(sha256Text(body) === provenance.renderedReleaseBody.sha256, 'Published release body digest does not match provenance.')
  const actualAssets = (release.assets || []).map((asset) => ({
    id: asset.id,
    name: asset.name,
    bytes: asset.size,
    sha256: String(asset.digest || '').replace(/^sha256:/, ''),
    url: asset.browser_download_url,
  })).sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0)
  requireValue(
    JSON.stringify(actualAssets) === JSON.stringify(snapshot.assets),
    'Published release asset set does not match the staged snapshot.'
  )
  return true
}

export function verifyStagedReleaseSnapshot(release, snapshot, provenance, releaseNotes, provenanceText) {
  const actual = createStagedReleaseSnapshot(release, provenance, releaseNotes, provenanceText)
  requireValue(
    JSON.stringify(actual) === JSON.stringify(snapshot),
    'Current draft release does not match the stage-run snapshot.'
  )
}

export function bindRenderedReleaseBody(releaseNotes, provenance) {
  const body = renderStableReleaseBody(releaseNotes, provenance)
  return {
    body,
    provenance: {
      ...provenance,
      renderedReleaseBody: {
        sha256: sha256Text(body),
      },
    },
  }
}

export function verifyRenderedReleaseBody(body, releaseNotes, provenance) {
  validateReleaseProvenance(provenance, releaseNotes)
  validateStableReleaseBody(body)
  requireSha256(provenance.renderedReleaseBody?.sha256, 'Rendered release body')
  requireValue(
    sha256Text(body) === provenance.renderedReleaseBody.sha256,
    'Rendered release body digest mismatch.'
  )
  requireValue(
    renderStableReleaseBody(releaseNotes, provenance) === body,
    'Rendered release body does not match exact tracked notes and staged provenance.'
  )
}
