#!/usr/bin/env node

import { spawn } from 'node:child_process'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')

async function runScript(scriptName) {
  const child = spawn(process.execPath, [path.join(repoRoot, 'scripts', scriptName)], {
    cwd: repoRoot,
    env: process.env,
    stdio: 'inherit',
  })

  const exitCode = await new Promise((resolve) => {
    child.once('exit', (code) => resolve(code ?? 0))
  })

  if (exitCode !== 0) {
    throw new Error(`${scriptName} failed with exit code ${exitCode}`)
  }
}

async function main() {
  await runScript('smoke-test-macos-install-lanes.mjs')
  await runScript('smoke-test-ios-companion-compat.mjs')
  console.log('RoachNet release gates passed.')
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
