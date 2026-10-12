#!/usr/bin/env node
// Fails when a release artifact carries details of the Mac that built it:
// its home folder or workspace paths (debug info, #filePath strings, logs),
// its host names, or its LAN addresses. Nothing here names a person or a
// machine: every value is read from the build Mac when the audit runs, and
// matches are reported by kind and file, never by value, so the output is
// safe to paste into a public gate document.
//
//   node scripts/audit-release-privacy.mjs [path ...]
//
// Paths can be app bundles, folders, single files, .zip or .ipa archives
// (unpacked to a temporary folder first). With none, it checks the built
// apps in native/macos/dist.
import { execFileSync } from 'node:child_process'
import { existsSync, lstatSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

/** Words that are part of the product and would match everywhere. */
const productWords = new Set(['roachnet', 'roachwares', 'roach', 'localhost', 'mac', 'macbook', 'imac', 'studio', 'mini'])

function quiet(command, args) {
  try {
    return execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch {
    return ''
  }
}

function addNeedle(needles, kind, value, { caseInsensitive = false, boundary = false } = {}) {
  if (!value) return
  const text = String(value)
  if (text.length < 4 || productWords.has(text.toLowerCase())) return
  if (needles.some((needle) => needle.text === text && needle.kind === kind)) return
  needles.push({ kind, text, caseInsensitive, boundary })
}

/** Everything about this Mac that must not end up in a shipped file. */
export function buildMachineNeedles({ home = os.homedir(), root = repoRoot, hostNames, addresses } = {}) {
  const needles = []
  addNeedle(needles, 'home folder path', home.endsWith('/') ? home : `${home}/`)
  addNeedle(needles, 'workspace path', root)
  addNeedle(needles, 'workspace path', path.dirname(root))
  const volume = root.match(/^\/Volumes\/[^/]+\//)
  if (volume) addNeedle(needles, 'build volume path', volume[0])

  const names = hostNames ?? [
    os.hostname(),
    quiet('scutil', ['--get', 'ComputerName']),
    quiet('scutil', ['--get', 'LocalHostName']),
    quiet('scutil', ['--get', 'HostName']),
  ]
  for (const name of names) {
    if (!name) continue
    addNeedle(needles, 'host name', name, { caseInsensitive: true, boundary: true })
    addNeedle(needles, 'host name', name.split('.')[0], { caseInsensitive: true, boundary: true })
  }

  const interfaces = addresses ?? Object.values(os.networkInterfaces()).flat().filter(Boolean)
  for (const entry of interfaces) {
    if (entry.internal) continue
    if (entry.family === 'IPv4' || entry.family === 4) {
      if (/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/.test(entry.address)) {
        addNeedle(needles, 'LAN address', entry.address, { boundary: true })
      }
    }
    if (entry.mac && entry.mac !== '00:00:00:00:00:00') addNeedle(needles, 'network hardware address', entry.mac, { caseInsensitive: true })
  }
  return needles
}

/** The byte strings to look for: the value as is, plus its common spellings when case doesn't matter. */
function variants(needle) {
  const text = needle.text
  const spellings = needle.caseInsensitive
    ? [text, text.toLowerCase(), text.toUpperCase(), text.charAt(0).toUpperCase() + text.slice(1).toLowerCase()]
    : [text]
  return [...new Set(spellings)].map((spelling) => Buffer.from(spelling, 'utf8'))
}

const wordByte = (byte) => (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte === 45 || byte === 95

/** Buffer.indexOf keeps this fast and light on large model files; boundary needles skip hits inside longer words. */
function contains(buffer, needle) {
  for (const bytes of needle.bytes) {
    let at = buffer.indexOf(bytes)
    while (at !== -1) {
      if (!needle.boundary) return true
      const before = at > 0 ? buffer[at - 1] : 0
      const after = at + bytes.length < buffer.length ? buffer[at + bytes.length] : 0
      if (!wordByte(before) && before !== 46 && !wordByte(after)) return true
      at = buffer.indexOf(bytes, at + 1)
    }
  }
  return false
}

function* walk(target) {
  const info = lstatSync(target, { throwIfNoEntry: false })
  if (!info || info.isSymbolicLink()) return
  if (info.isDirectory()) {
    for (const entry of readdirSync(target)) yield* walk(path.join(target, entry))
  } else if (info.isFile()) {
    yield target
  }
}

/** Finds needles in the files under `targets`. Archives are unpacked and checked too. */
export function scan(targets, needles) {
  const compiled = needles.map((needle) => ({ ...needle, bytes: variants(needle) }))
  const findings = []
  const scratch = []
  // Files are shown under the target's own name, so the report never prints this Mac's paths.
  const queue = targets.map((target) => ({ target, label: path.basename(target) }))
  try {
    while (queue.length > 0) {
      const { target, label } = queue.shift()
      for (const file of walk(target)) {
        const shown = path.join(label, path.relative(target, file)) || label
        if (/\.(zip|ipa)$/i.test(file)) {
          const out = mkdtempSync(path.join(os.tmpdir(), 'rn-privacy-'))
          scratch.push(out)
          try {
            if (process.platform === 'darwin') execFileSync('ditto', ['-x', '-k', file, out], { stdio: 'ignore' })
            else execFileSync('unzip', ['-q', file, '-d', out], { stdio: 'ignore' })
            queue.push({ target: out, label: `${shown}!` })
          } catch {
            findings.push({ file: shown, kind: 'archive that could not be opened for checking' })
          }
          continue
        }
        // Raw bytes, so strings inside binaries are found too.
        const buffer = readFileSync(file)
        const kinds = new Set(compiled.filter((needle) => contains(buffer, needle)).map((needle) => needle.kind))
        for (const kind of kinds) findings.push({ file: shown, kind })
      }
    }
  } finally {
    for (const folder of scratch) rmSync(folder, { recursive: true, force: true })
  }
  return findings
}

function main() {
  const args = process.argv.slice(2)
  const targets = args.length > 0
    ? args.map((arg) => path.resolve(arg))
    : ['RoachNet.app', 'RoachNet Setup.app'].map((name) => path.join(repoRoot, 'native', 'macos', 'dist', name)).filter(existsSync)
  if (targets.length === 0) {
    console.error('Nothing to check: build the apps first or pass paths.')
    process.exit(2)
  }
  const needles = buildMachineNeedles()
  const findings = scan(targets, needles)
  if (findings.length === 0) {
    console.log(`Release privacy audit passed: ${targets.length} target(s), ${needles.length} build-machine details checked.`)
    return
  }
  console.error('Release privacy audit failed. These files carry details of the Mac that built them:')
  for (const { file, kind } of findings) console.error(`  ${kind}: ${file}`)
  console.error('Strip debug info (strip -S) and remove local paths, host names or addresses before shipping.')
  process.exit(1)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main()
