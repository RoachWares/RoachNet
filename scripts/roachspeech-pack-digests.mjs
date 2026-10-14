#!/usr/bin/env node
// Records, verifies and cross-checks the RoachSpeech pack digests (ROA-40).
//
//   node scripts/roachspeech-pack-digests.mjs --verify          compare the local packs with the manifest
//   node scripts/roachspeech-pack-digests.mjs --check-upstream  compare the local packs with the pinned
//                                                               Hugging Face commits (needs the network)
//   node scripts/roachspeech-pack-digests.mjs --write           record the local packs (after a check)
//   node scripts/roachspeech-pack-digests.mjs --record-inputs   record the pinned commits' file sizes and
//                                                               digests (needs the network)

import { writeFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import {
  computePackDigests,
  gitBlobSha1,
  listPackFiles,
  readDigestManifest,
  roachSpeechDigestSchema,
  sha256File,
  verifyPackAgainstManifest,
} from './lib/roachspeech_pack_digests.mjs'
import { exitForError, listUpstreamFiles, readUpstreamInputs, upstreamInputsSchema, upstreamKey } from './lib/roachspeech_upstream_fetch.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
export const roachSpeechDigestManifestPath = path.join(repoRoot, 'docs', 'release-gates', 'roachspeech-pack-digests.json')
export const roachSpeechUpstreamInputsPath = path.join(repoRoot, 'docs', 'release-gates', 'roachspeech-upstream-inputs.json')
const packsRoot = path.join(repoRoot, 'native', 'macos', 'Vendor', 'RoachSpeech', 'ModelPacks')

// The commits each importer pins (its defaultRepository / defaultRevision);
// release-workflow-security.test.mjs keeps these in step with the importers.
export const roachSpeechUpstreams = {
  'roachwhisper-openai-whisper-base-en-coreml': [
    { repository: 'argmaxinc/whisperkit-coreml', revision: '0f63a7800b00dd0226abd051b906c246e1907482' },
    { repository: 'openai/whisper-base.en', revision: '911407f4214e0e1d82085af863093ec0b66f9cd6' },
  ],
  'roachvoice-kokoro-82m-int8-coreml': [
    { repository: 'aufklarer/Kokoro-82M-CoreML-INT8', revision: '4bc7df470ea4612a5b6539af16ebf301a027f491' },
  ],
  'roachvoice-chatterbox-coreml': [
    { repository: 'yepher/screen-cut-pro-tts-coreml', revision: 'f4fae0751b59970c170ca8d40cbf0c53dc20ad37' },
  ],
}

// The listings the importers read: each pinned commit, and for WhisperKit the
// one model folder it takes. Their files' sizes and digests are recorded in
// roachspeech-upstream-inputs.json, so imports need no listing request and can
// verify every file they download (ROA-96).
export const roachSpeechUpstreamListings = [
  { repository: 'argmaxinc/whisperkit-coreml', revision: '0f63a7800b00dd0226abd051b906c246e1907482', subpath: 'openai_whisper-base.en' },
  { repository: 'openai/whisper-base.en', revision: '911407f4214e0e1d82085af863093ec0b66f9cd6' },
  { repository: 'aufklarer/Kokoro-82M-CoreML-INT8', revision: '4bc7df470ea4612a5b6539af16ebf301a027f491' },
  { repository: 'yepher/screen-cut-pro-tts-coreml', revision: 'f4fae0751b59970c170ca8d40cbf0c53dc20ad37' },
]

async function upstreamTree(source) {
  return listUpstreamFiles(source, { manifest: readUpstreamInputs(roachSpeechUpstreamInputsPath) })
}

async function recordUpstreamInputs() {
  const trees = {}
  for (const source of roachSpeechUpstreamListings) {
    const files = await listUpstreamFiles(source)
    trees[upstreamKey(source)] = files
      .map((entry) => entry.lfs?.oid
        ? { path: entry.path, bytes: entry.lfs.size, sha256: entry.lfs.oid }
        : { path: entry.path, bytes: entry.size, gitBlobSha1: entry.oid })
      .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
    console.log(`${upstreamKey(source)}: ${files.length} files`)
  }
  const manifest = {
    schema: upstreamInputsSchema,
    note: 'Size and digest of every file in the pinned Hugging Face commits the RoachSpeech importers read: SHA-256 for LFS files, the git blob id for the rest. Importers verify each file they download against this, and list a recorded commit from it with no request.',
    recordedAt: new Date().toISOString().slice(0, 10),
    trees,
  }
  writeFileSync(roachSpeechUpstreamInputsPath, `${JSON.stringify(manifest, null, 2)}\n`)
  console.log(`Wrote ${path.relative(repoRoot, roachSpeechUpstreamInputsPath)}`)
}

/** Matches every local file to an upstream file by SHA-256 (LFS) or git blob id. */
async function checkUpstream(packID) {
  const sources = roachSpeechUpstreams[packID]
  if (!sources) throw new Error(`No pinned upstream for ${packID}.`)
  const bySha256 = new Map()
  const byGitOid = new Map()
  for (const source of sources) {
    for (const entry of await upstreamTree(source)) {
      const where = `${source.repository}@${source.revision.slice(0, 12)}:${entry.path}`
      if (entry.lfs?.oid) bySha256.set(entry.lfs.oid, where)
      if (entry.oid) byGitOid.set(entry.oid, where)
    }
  }
  const root = path.join(packsRoot, packID)
  const files = {}
  for (const relative of listPackFiles(root)) {
    const full = path.join(root, relative)
    const sha256 = await sha256File(full)
    files[relative] = bySha256.get(sha256) ?? byGitOid.get(gitBlobSha1(full)) ?? null
  }
  return files
}

async function main() {
  const mode = process.argv[2]
  const packIDs = Object.keys(roachSpeechUpstreams)
  if (mode === '--record-inputs') {
    await recordUpstreamInputs()
    return
  }
  if (mode === '--verify') {
    const manifest = readDigestManifest(roachSpeechDigestManifestPath)
    for (const packID of packIDs) {
      const count = await verifyPackAgainstManifest(manifest, packID, path.join(packsRoot, packID))
      console.log(`${packID}: ${count} files match`)
    }
    return
  }
  if (mode === '--check-upstream' || mode === '--write') {
    const packs = {}
    for (const packID of packIDs) {
      const upstream = await checkUpstream(packID)
      const digests = await computePackDigests(path.join(packsRoot, packID))
      const matched = Object.values(upstream).filter(Boolean).length
      const local = Object.entries(upstream).filter(([, where]) => !where).map(([file]) => file)
      console.log(`${packID}: ${matched}/${Object.keys(upstream).length} files byte-identical to the pinned upstream commit`)
      for (const file of local) console.log(`  written by the importer, not upstream: ${file}`)
      packs[packID] = {
        upstream: roachSpeechUpstreams[packID],
        files: Object.fromEntries(Object.entries(digests).map(([file, digest]) => [file, { ...digest, upstream: upstream[file] }])),
      }
    }
    if (mode === '--write') {
      const manifest = {
        schema: roachSpeechDigestSchema,
        note: 'SHA-256 and size of every file in the RoachSpeech Core ML packs RoachNet bundles and publishes. "upstream" names the file in the pinned Hugging Face commit with identical bytes; null marks files the importer writes itself (pack manifest, tokenizer, voice tables, parity fixtures).',
        recordedAt: new Date().toISOString().slice(0, 10),
        packs,
      }
      writeFileSync(roachSpeechDigestManifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
      console.log(`Wrote ${path.relative(repoRoot, roachSpeechDigestManifestPath)}`)
    }
    return
  }
  console.error('usage: roachspeech-pack-digests.mjs --verify | --check-upstream | --write | --record-inputs')
  process.exitCode = 2
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch(exitForError)
}
