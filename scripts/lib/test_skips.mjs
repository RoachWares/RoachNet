// Finds the tests a run skipped and checks each against the recorded
// dispositions in docs/release-gates/qualification-skips.json, so a test that
// needs a model, a fixture or a GPU can't drop out of qualification unnoticed.

import fs from 'node:fs'

export const skipDispositionsSchema = 'org.roachnet.qualification-skips.v1'
export const platforms = ['macos', 'linux']
// "always": the test can't run on that platform at all, so a skip is expected
// everywhere. "ci": CI lacks the models or fixtures, so a skip is expected
// there, but a qualification run must run the test.
export const scopes = ['always', 'ci']
export const modes = ['ci', 'qualification']

/**
 * Skips in `swift test` output. macOS prints
 *   path:line: -[Module.Class testName] : Test skipped - reason
 * and Linux prints
 *   path:line: Class.testName : Test skipped - reason
 * Each is returned as { id: 'Class.testName', reason }.
 */
export function xctestSkips(text) {
  const skips = new Map()
  const darwin = /^.*?: -\[(?:[A-Za-z_][\w]*\.)?([A-Za-z_]\w*) (\w+)\] : Test skipped(?: - |: )(.*)$/
  const linux = /^.*?:\d+: ([A-Za-z_]\w*)\.(\w+) : Test skipped(?: - |: )(.*)$/
  for (const line of text.split(/\r?\n/)) {
    const match = darwin.exec(line) ?? linux.exec(line)
    if (match) skips.set(`${match[1]}.${match[2]}`, match[3].trim())
  }
  return [...skips].map(([id, reason]) => ({ id, reason, kind: 'xctest' }))
}

/** Skips in node:test TAP output, top-level and nested: `ok 7 - name # SKIP reason`. */
export function tapSkips(text) {
  const skips = new Map()
  for (const line of text.split(/\r?\n/)) {
    const match = /^\s*ok \d+ - (.*?) # SKIP\b\s*(.*)$/.exec(line)
    if (match) skips.set(match[1].trim(), match[2].trim())
  }
  return [...skips].map(([id, reason]) => ({ id, reason, kind: 'tap' }))
}

export function readDispositions(file) {
  const manifest = JSON.parse(fs.readFileSync(file, 'utf8'))
  if (manifest.schema !== skipDispositionsSchema || !Array.isArray(manifest.skips)) {
    throw new Error(`${file} is not a ${skipDispositionsSchema} file.`)
  }
  for (const entry of manifest.skips) {
    const where = `${file}: ${entry.id ?? '(no id)'}`
    if (!['xctest', 'tap'].includes(entry.kind)) throw new Error(`${where}: kind must be xctest or tap`)
    if (typeof entry.id !== 'string' || !entry.id) throw new Error(`${where}: needs an id`)
    if (!Array.isArray(entry.platforms) || !entry.platforms.length || entry.platforms.some((p) => !platforms.includes(p))) {
      throw new Error(`${where}: platforms must be a non-empty list of ${platforms.join(', ')}`)
    }
    if (!scopes.includes(entry.scope)) throw new Error(`${where}: scope must be ${scopes.join(' or ')}`)
    for (const field of ['why', 'disposition']) {
      if (typeof entry[field] !== 'string' || entry[field].trim().length < 10) throw new Error(`${where}: needs a ${field}`)
    }
  }
  return manifest.skips
}

/**
 * Sorts each skip into `allowed` (recorded for this platform and mode, with
 * its disposition) or `unrecorded`. A qualification run fails on any
 * unrecorded skip; there, only skips with scope "always" are allowed.
 */
export function judgeSkips(skips, dispositions, platform, mode = 'qualification') {
  if (!platforms.includes(platform)) throw new Error(`unknown platform ${platform}`)
  if (!modes.includes(mode)) throw new Error(`unknown mode ${mode}`)
  const allowed = []
  const unrecorded = []
  for (const skip of skips) {
    const entry = dispositions.find((item) => item.kind === skip.kind && item.id === skip.id && item.platforms.includes(platform)
      && (item.scope === 'always' || mode === 'ci'))
    if (entry) allowed.push({ ...skip, why: entry.why, disposition: entry.disposition })
    else unrecorded.push(skip)
  }
  return { allowed, unrecorded }
}

/** A Markdown report, for a terminal or a GitHub job summary. */
export function skipReport({ allowed, unrecorded }, platform, mode = 'qualification') {
  // Backslashes first, so a "\|" in a test name can't undo the escaped pipe.
  const cell = (value) => String(value || '(none given)').replace(/\\/g, '\\\\').replace(/\|/g, '\\|').replace(/\r?\n/g, ' ')
  const lines = [`### Skipped tests (${platform}, ${mode})`, '']
  if (!allowed.length && !unrecorded.length) return [...lines, 'No test was skipped.', ''].join('\n')
  if (unrecorded.length) {
    const lead = mode === 'qualification' ? 'This qualification run fails on them' : 'A qualification run would fail on them'
    lines.push(`**${unrecorded.length} skipped without a disposition that allows it here.** ${lead}:`, '', '| Test | Reason given |', '| --- | --- |')
    for (const skip of unrecorded) lines.push(`| ${cell(skip.id)} | ${cell(skip.reason)} |`)
    lines.push('')
  }
  if (allowed.length) {
    lines.push(`${allowed.length} skipped with a recorded disposition:`, '', '| Test | Why | Disposition |', '| --- | --- | --- |')
    for (const skip of allowed) lines.push(`| ${cell(skip.id)} | ${cell(skip.why)} | ${cell(skip.disposition)} |`)
    lines.push('')
  }
  return lines.join('\n')
}
