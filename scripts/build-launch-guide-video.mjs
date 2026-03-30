#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')

const slides = [
  'roachnet-home-view.svg',
  'roachnet-roachclaw-view.svg',
  'roachnet-maps-view.svg',
  'roachnet-runtime-view.svg',
]

const slidesDir = path.join(repoRoot, 'website', 'assets', 'screens')
const outputDir = path.join(repoRoot, 'native', 'macos', 'Sources', 'RoachNetApp', 'Resources')
const outputPath = path.join(outputDir, 'roachnet-launch-guide.mp4')

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd || repoRoot,
    stdio: options.stdio || 'pipe',
    encoding: 'utf8',
  })

  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed with exit code ${result.status}\n${result.stderr || ''}`)
  }

  return result
}

function assertCommandExists(command) {
  const result = spawnSync('bash', ['-lc', `command -v ${command}`], {
    cwd: repoRoot,
    stdio: 'pipe',
    encoding: 'utf8',
  })

  if (result.status !== 0) {
    throw new Error(`Required command not found: ${command}`)
  }
}

function main() {
  slides.forEach((slide) => {
    const slidePath = path.join(slidesDir, slide)
    if (!existsSync(slidePath)) {
      throw new Error(`Missing slide asset at ${slidePath}`)
    }
  })

  assertCommandExists('sips')
  assertCommandExists('ffmpeg')

  mkdirSync(outputDir, { recursive: true })

  const tempDir = mkdtempSync(path.join(os.tmpdir(), 'roachnet-launch-guide-'))

  try {
    const pngPaths = slides.map((slide, index) => {
      const slidePath = path.join(slidesDir, slide)
      const pngPath = path.join(tempDir, `slide-${String(index + 1).padStart(2, '0')}.png`)
      run('sips', ['-s', 'format', 'png', slidePath, '--out', pngPath], { stdio: 'pipe' })
      return pngPath
    })

    const concatPath = path.join(tempDir, 'slides.txt')
    writeFileSync(
      concatPath,
      pngPaths.map((pngPath) => `file '${pngPath.replace(/'/g, "'\\''")}'\nduration 5`).join('\n') +
        `\nfile '${pngPaths[pngPaths.length - 1].replace(/'/g, "'\\''")}'\n`,
      'utf8'
    )

    run(
      'ffmpeg',
      [
        '-y',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        concatPath,
        '-vf',
        'fps=30,scale=1728:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=#090d12,format=yuv420p',
        '-an',
        '-movflags',
        '+faststart',
        '-c:v',
        'libx264',
        '-crf',
        '20',
        outputPath,
      ],
      { stdio: 'inherit' }
    )

    process.stdout.write(`${outputPath}\n`)
  } finally {
    rmSync(tempDir, { recursive: true, force: true })
  }
}

main()
