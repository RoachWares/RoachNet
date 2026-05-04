#!/usr/bin/env node

import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')

function git(args) {
  return execFileSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
}

function isTextCandidate(filePath) {
  const ext = path.extname(filePath).toLowerCase()
  const binaryExtensions = new Set([
    '.app',
    '.bin',
    '.dmg',
    '.gif',
    '.icns',
    '.ico',
    '.ipa',
    '.jpeg',
    '.jpg',
    '.mov',
    '.mp4',
    '.pdf',
    '.png',
    '.tar',
    '.tgz',
    '.webp',
    '.zip',
    '.zim',
  ])
  if (binaryExtensions.has(ext)) return false

  const absolute = path.join(repoRoot, filePath)
  try {
    return fs.statSync(absolute).size <= 2_000_000
  } catch {
    return false
  }
}

const trackedFiles = git(['ls-files'])
  .split('\n')
  .map((line) => line.trim())
  .filter(Boolean)

const failures = []

const blockedExactFiles = new Map([
  ['MEMORY.MD', 'local handoff memory can contain machine paths, adjacent repos, and release notes not meant for public GitHub'],
  ['docs/BRAND_STYLE.md', 'brand/copy strategy is internal guidance; public pages should use the voice without exposing the project map'],
])

const blockedPrefixes = new Map([
  ['native/windows/', 'Windows beta source is outside the Apple Silicon native public source boundary for this release'],
])

const blockedGlobs = [
  {
    test: (file) => file.startsWith('install/') && /\.(zim|zip|tar|tgz|gz)$/i.test(file),
    reason: 'install archives are bundled/download artifacts, not source required to build the native macOS app',
  },
  {
    test: (file) => /(^|\/)\.env($|\.)/.test(file),
    reason: 'environment files do not belong on the public source surface',
  },
]

for (const file of trackedFiles) {
  const exactReason = blockedExactFiles.get(file)
  if (exactReason) {
    failures.push(`${file}: ${exactReason}`)
    continue
  }

  for (const [prefix, reason] of blockedPrefixes) {
    if (file.startsWith(prefix)) {
      failures.push(`${file}: ${reason}`)
      break
    }
  }

  for (const rule of blockedGlobs) {
    if (rule.test(file)) {
      failures.push(`${file}: ${rule.reason}`)
      break
    }
  }
}

function literalPattern(parts, flags = 'g') {
  const value = parts.join('')
  const escaped = value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(escaped, flags)
}

const personalPatterns = [
  { pattern: literalPattern(['/', 'Users', '/', 'ro', 'ach']), label: 'local user path' },
  { pattern: literalPattern(['/', 'Volumes', '/', 'Par', 'odox']), label: 'local volume path' },
  { pattern: literalPattern(['/', 'Volumes', '/', 'Bl', 'ack']), label: 'local volume path' },
  { pattern: literalPattern(['Bren', 'nans', '-', 'Mac'], 'gi'), label: 'personal machine name' },
  { pattern: literalPattern(['les', 'her', 'ist'], 'gi'), label: 'personal contact handle' },
  { pattern: literalPattern(['gm', 'ail', '.', 'com'], 'gi'), label: 'personal email domain in repo text' },
  { pattern: literalPattern(['Roach', 'Man', 'Sky'], 'gi'), label: 'private adjacent project name' },
  { pattern: literalPattern(['TG', '$', 'Regime'], 'gi'), label: 'private label/project context' },
]

const upstreamIdentityPatterns = [
  { pattern: /cosmistack/gi, label: 'private upstream organization identity' },
  { pattern: /project[-_ ]nomad/gi, label: 'old imported upstream identity' },
  { pattern: /projectnomad/gi, label: 'old imported upstream domain' },
  { pattern: /\bNOMAD\b/g, label: 'old imported upstream environment prefix' },
  { pattern: /\bNomad\b/g, label: 'old imported upstream product name' },
  { pattern: /Crosstalk[- ]Solutions/gi, label: 'old imported upstream publisher identity' },
  { pattern: /crosstalksolutions/gi, label: 'old imported upstream community URL' },
  { pattern: /chriscrosstalk/gi, label: 'old imported upstream maintainer handle' },
]

for (const file of trackedFiles) {
  if (file === 'scripts/audit-public-release-surface.mjs') continue
  if (file === 'LICENSE') continue
  if (!isTextCandidate(file)) continue

  const absolute = path.join(repoRoot, file)
  let contents = ''
  try {
    contents = fs.readFileSync(absolute, 'utf8')
  } catch {
    continue
  }

  for (const { pattern, label } of personalPatterns) {
    pattern.lastIndex = 0
    if (pattern.test(contents)) {
      failures.push(`${file}: contains ${label}`)
    }
  }

  for (const { pattern, label } of upstreamIdentityPatterns) {
    pattern.lastIndex = 0
    if (pattern.test(contents)) {
      failures.push(`${file}: contains ${label}`)
    }
  }

  if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(contents)) {
    failures.push(`${file}: contains private key material`)
  }
}

if (failures.length > 0) {
  console.error('Public release surface audit failed.')
  console.error('')
  for (const failure of failures) {
    console.error(`- ${failure}`)
  }
  console.error('')
  console.error('Fix these before pushing to GitHub, Homebrew, or roachnet.org.')
  process.exit(1)
}

console.log('Public release surface audit passed.')
