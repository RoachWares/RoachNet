import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  computePackDigests,
  readDigestManifest,
  roachSpeechDigestSchema,
  verifyImportedUpstreamFiles,
  verifyPackAgainstManifest,
} from '../lib/roachspeech_pack_digests.mjs'
import { roachSpeechDigestManifestPath, roachSpeechUpstreams } from '../roachspeech-pack-digests.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

test('pack digests catch changed, missing and extra files (ROA-40)', async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'roachspeech-digests-'))
  try {
    const pack = path.join(root, 'pack')
    mkdirSync(path.join(pack, 'Model.mlmodelc'), { recursive: true })
    writeFileSync(path.join(pack, 'RoachSpeechPack.json'), '{"id":"pack"}\n')
    writeFileSync(path.join(pack, 'Model.mlmodelc', 'weights.bin'), 'weights')
    const files = await computePackDigests(pack)
    const manifest = { schema: roachSpeechDigestSchema, packs: { pack: { files } } }
    assert.equal(await verifyPackAgainstManifest(manifest, 'pack', pack), 2)

    writeFileSync(path.join(pack, 'Model.mlmodelc', 'weights.bin'), 'weightz')
    await assert.rejects(verifyPackAgainstManifest(manifest, 'pack', pack), /weights\.bin has SHA-256/)
    writeFileSync(path.join(pack, 'Model.mlmodelc', 'weights.bin'), 'weights')
    writeFileSync(path.join(pack, 'extra.txt'), 'x')
    await assert.rejects(verifyPackAgainstManifest(manifest, 'pack', pack), /unexpected extra\.txt/)
    rmSync(path.join(pack, 'extra.txt'))
    rmSync(path.join(pack, 'RoachSpeechPack.json'))
    await assert.rejects(verifyPackAgainstManifest(manifest, 'pack', pack), /missing RoachSpeechPack\.json/)
    await assert.rejects(verifyPackAgainstManifest(manifest, 'other', pack), /no recorded digests/)

    // A re-import only has to reproduce the files that came from upstream.
    writeFileSync(path.join(pack, 'RoachSpeechPack.json'), '{"id":"pack","importedAt":"later"}\n')
    files['Model.mlmodelc/weights.bin'].upstream = 'org/repo@abc:weights.bin'
    const manifestPath = path.join(root, 'digests.json')
    writeFileSync(manifestPath, JSON.stringify(manifest))
    assert.equal(await verifyImportedUpstreamFiles(manifestPath, 'pack', pack), 1)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('the recorded upstreams are the commits the importers pin', () => {
  const importers = {
    'roachwhisper-openai-whisper-base-en-coreml': 'import-roachwhisper-coreml-from-whisperkit.mjs',
    'roachvoice-kokoro-82m-int8-coreml': 'import-roachvoice-kokoro-coreml.mjs',
    'roachvoice-chatterbox-coreml': 'import-roachvoice-chatterbox-coreml.mjs',
  }
  for (const [packID, script] of Object.entries(importers)) {
    const source = readFileSync(path.join(repoRoot, 'scripts', script), 'utf8')
    for (const { repository, revision } of roachSpeechUpstreams[packID]) {
      assert.ok(source.includes(revision), `${script} no longer pins ${repository}@${revision}`)
    }
    assert.match(source, /verifyImportedUpstreamFiles/, `${script} must check a fresh import against the recorded digests`)
  }
  const builder = readFileSync(path.join(repoRoot, 'scripts', 'build-native-macos-apps.mjs'), 'utf8')
  assert.equal(builder.match(/await requireRecordedRoachSpeechPack\(/g)?.length, 2, 'bundling and archiving must both check digests')
})

test('the committed digest manifest covers every pack with full SHA-256s', () => {
  const manifest = readDigestManifest(roachSpeechDigestManifestPath)
  assert.ok(manifest, 'docs/release-gates/roachspeech-pack-digests.json is missing')
  for (const packID of Object.keys(roachSpeechUpstreams)) {
    const files = manifest.packs[packID]?.files
    assert.ok(files && Object.keys(files).length > 0, `${packID} has no recorded files`)
    for (const [file, record] of Object.entries(files)) {
      assert.match(record.sha256, /^[0-9a-f]{64}$/, `${packID}/${file}`)
      assert.ok(Number.isInteger(record.bytes) && record.bytes >= 0, `${packID}/${file}`)
    }
    assert.ok(Object.values(files).some((record) => record.upstream), `${packID} has no file traced to its upstream commit`)
  }
})
