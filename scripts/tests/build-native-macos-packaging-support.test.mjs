import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { writeSha256Sidecar } from '../build-native-macos-packaging-support.mjs'

test('writeSha256Sidecar writes the current digest beside the artifact', async () => {
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), 'roachnet-packaging-test-'))
  const artifactPath = path.join(tempRoot, 'RoachNet-Setup-macOS.dmg')
  const artifactContents = 'roachnet release artifact'

  writeFileSync(artifactPath, artifactContents, 'utf8')

  const sidecarPath = await writeSha256Sidecar(artifactPath)
  const expectedDigest = createHash('sha256').update(artifactContents).digest('hex')

  assert.equal(sidecarPath, `${artifactPath}.sha256`)
  assert.equal(
    readFileSync(sidecarPath, 'utf8'),
    `${expectedDigest}  ${path.basename(artifactPath)}\n`
  )
})
