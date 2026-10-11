// Per-file digests for the RoachSpeech Core ML packs (ROA-40, review finding S3).
//
// The packs are third-party Hugging Face conversions. The importers pin a
// commit, but a commit pin alone does not say which bytes shipped. The
// committed manifest records the SHA-256 and size of every file in every
// pack, and builds refuse to bundle or archive a pack whose files differ.

import { createHash } from 'node:crypto'
import { createReadStream, existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'

export const roachSpeechDigestSchema = 'org.roachnet.roachspeech-pack-digests.v1'

/** Every regular file under `root`, as sorted POSIX paths relative to it. */
export function listPackFiles(root) {
  const files = []
  const walk = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.name === '.DS_Store') continue
      const full = path.join(directory, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (entry.isFile()) files.push(path.relative(root, full).split(path.sep).join('/'))
      else throw new Error(`RoachSpeech pack ${root} contains ${full}, which is not a regular file.`)
    }
  }
  walk(root)
  return files.sort()
}

export function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256')
    createReadStream(filePath)
      .on('error', reject)
      .on('data', (chunk) => hash.update(chunk))
      .on('end', () => resolve(hash.digest('hex')))
  })
}

/** Git's blob id for a file (what the Hugging Face tree API reports for non-LFS files). */
export function gitBlobSha1(filePath) {
  const content = readFileSync(filePath)
  return createHash('sha1').update(`blob ${content.length}\0`).update(content).digest('hex')
}

export async function computePackDigests(packRoot) {
  const files = {}
  for (const relative of listPackFiles(packRoot)) {
    const full = path.join(packRoot, relative)
    files[relative] = { sha256: await sha256File(full), bytes: statSync(full).size }
  }
  return files
}

export function readDigestManifest(manifestPath) {
  if (!existsSync(manifestPath)) return null
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  if (manifest.schema !== roachSpeechDigestSchema || typeof manifest.packs !== 'object') {
    throw new Error(`${manifestPath} is not a ${roachSpeechDigestSchema} manifest.`)
  }
  return manifest
}

/**
 * Throws unless `packRoot` holds exactly the files the manifest records for
 * `packID`, byte for byte. Returns the number of files checked.
 */
export async function verifyPackAgainstManifest(manifest, packID, packRoot) {
  const expected = manifest?.packs?.[packID]?.files
  if (!expected) throw new Error(`RoachSpeech pack ${packID} has no recorded digests; run node scripts/roachspeech-pack-digests.mjs --write after checking it.`)
  const actual = listPackFiles(packRoot)
  const missing = Object.keys(expected).filter((file) => !actual.includes(file))
  const extra = actual.filter((file) => !(file in expected))
  const problems = [...missing.map((file) => `missing ${file}`), ...extra.map((file) => `unexpected ${file}`)]
  for (const file of actual.filter((name) => name in expected)) {
    const full = path.join(packRoot, file)
    const bytes = statSync(full).size
    if (bytes !== expected[file].bytes) {
      problems.push(`${file} is ${bytes} bytes, expected ${expected[file].bytes}`)
      continue
    }
    const digest = await sha256File(full)
    if (digest !== expected[file].sha256) problems.push(`${file} has SHA-256 ${digest}, expected ${expected[file].sha256}`)
  }
  if (problems.length) {
    throw new Error(`RoachSpeech pack ${packID} does not match its recorded digests:\n  ${problems.slice(0, 20).join('\n  ')}`)
  }
  return actual.length
}

/**
 * After a fresh import: every file the manifest says came byte-for-byte from
 * the pinned upstream commit must have exactly the recorded bytes again.
 * Files the importer writes itself (timestamps, converted tables) are skipped.
 * Returns the number of files checked, or 0 when the pack isn't recorded.
 */
export async function verifyImportedUpstreamFiles(manifestPath, packID, packRoot) {
  const manifest = readDigestManifest(manifestPath)
  const expected = manifest?.packs?.[packID]?.files
  if (!expected) return 0
  const problems = []
  let checked = 0
  for (const [file, record] of Object.entries(expected)) {
    if (!record.upstream) continue
    const full = path.join(packRoot, file)
    if (!existsSync(full)) {
      problems.push(`missing ${file}`)
      continue
    }
    const digest = await sha256File(full)
    if (digest !== record.sha256) problems.push(`${file} has SHA-256 ${digest}, expected ${record.sha256}`)
    checked += 1
  }
  if (problems.length) {
    throw new Error(`The import of ${packID} does not match the recorded upstream bytes:\n  ${problems.slice(0, 20).join('\n  ')}`)
  }
  return checked
}
