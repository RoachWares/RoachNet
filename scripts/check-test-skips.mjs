#!/usr/bin/env node
// Lists every test a run skipped, with its recorded disposition.
//
//   node scripts/check-test-skips.mjs --platform macos --mode ci|qualification \
//     --xctest xctest.log --tap contract.tap [--strict] [--summary file]
//
// Each skip is matched against docs/release-gates/qualification-skips.json.
// In qualification mode only skips of tests that can't run on the platform
// at all are allowed; in ci mode, skips for missing models and fixtures are
// listed with their disposition too. --strict exits 1 on any skip that isn't
// allowed; qualification runs use it. --summary appends the Markdown report to
// a file (GITHUB_STEP_SUMMARY in CI).

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { judgeSkips, readDispositions, skipReport, tapSkips, xctestSkips } from './lib/test_skips.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
export const dispositionsPath = path.join(repoRoot, 'docs', 'release-gates', 'qualification-skips.json')

export function checkSkips({ platform, mode = 'qualification', xctest = [], tap = [], strict = false, dispositions = dispositionsPath }) {
  const skips = [
    ...xctest.flatMap((file) => xctestSkips(fs.readFileSync(file, 'utf8'))),
    ...tap.flatMap((file) => tapSkips(fs.readFileSync(file, 'utf8'))),
  ]
  const verdict = judgeSkips(skips, readDispositions(dispositions), platform, mode)
  return { ...verdict, report: skipReport(verdict, platform, mode), ok: !strict || verdict.unrecorded.length === 0 }
}

function parseArgs(argv) {
  const args = { xctest: [], tap: [], strict: false }
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    const value = () => {
      const next = argv[++index]
      if (!next) throw new Error(`${flag} needs a value`)
      return next
    }
    if (flag === '--platform') args.platform = value()
    else if (flag === '--mode') args.mode = value()
    else if (flag === '--xctest') args.xctest.push(value())
    else if (flag === '--tap') args.tap.push(value())
    else if (flag === '--summary') args.summary = value()
    else if (flag === '--dispositions') args.dispositions = value()
    else if (flag === '--strict') args.strict = true
    else throw new Error(`unknown option ${flag}`)
  }
  if (!args.platform) throw new Error('--platform macos|linux is required')
  if (!args.xctest.length && !args.tap.length) throw new Error('give at least one --xctest log or --tap file')
  return args
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const args = parseArgs(process.argv.slice(2))
    const result = checkSkips(args)
    console.log(result.report)
    if (args.summary) fs.appendFileSync(args.summary, `${result.report}\n`)
    if (process.env.GITHUB_ACTIONS === 'true') {
      for (const skip of result.unrecorded) console.log(`::warning title=Skipped test without a disposition::${skip.id}: ${skip.reason}`)
    }
    if (!result.ok) {
      console.error(`${result.unrecorded.length} skipped test(s) have no disposition that allows the skip (${args.platform}, ${args.mode ?? 'qualification'}).`)
      process.exitCode = 1
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : error)
    process.exitCode = 2
  }
}
