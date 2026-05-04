#!/usr/bin/env node

import { spawn } from 'node:child_process'
import { cp, mkdir, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const sourceIconPath = path.join(repoRoot, 'admin', 'public', 'roachnet-icon.png')
const desktopAssetsDir = path.join(repoRoot, 'desktop', 'assets')
const generatedDir = path.join(desktopAssetsDir, 'generated')
const mainIconPath = path.join(desktopAssetsDir, 'icon.png')

if (!existsSync(sourceIconPath)) {
  throw new Error(`Missing source icon at ${sourceIconPath}`)
}

function run(binary, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      cwd: repoRoot,
      env: {
        ...process.env,
        PATH: `/opt/homebrew/opt/node@24/bin:${process.env.PATH || ''}`,
      },
      stdio: 'inherit',
    })

    child.on('error', reject)
    child.on('close', (code) => {
      if (code === 0) {
        resolve()
        return
      }

      reject(new Error(`${binary} ${args.join(' ')} exited with code ${code}`))
    })
  })
}

await mkdir(desktopAssetsDir, { recursive: true })
await rm(generatedDir, { recursive: true, force: true })
await mkdir(generatedDir, { recursive: true })
await cp(sourceIconPath, mainIconPath, { force: true })

await run(process.platform === 'win32' ? 'npx.cmd' : 'npx', [
  'icon-gen',
  '-i',
  sourceIconPath,
  '-o',
  generatedDir,
  '--ico',
  '--ico-name',
  'icon',
  '--icns',
  '--icns-name',
  'icon',
  '--favicon',
  '--favicon-name',
  'icon-',
])

const generatedMacIconPath = path.join(generatedDir, 'icon.icns')
const generatedWindowsIconPath = path.join(generatedDir, 'icon.ico')

if (existsSync(generatedMacIconPath)) {
  await cp(generatedMacIconPath, path.join(desktopAssetsDir, 'icon.icns'), { force: true })
}

if (existsSync(generatedWindowsIconPath)) {
  await cp(generatedWindowsIconPath, path.join(desktopAssetsDir, 'icon.ico'), { force: true })
}
