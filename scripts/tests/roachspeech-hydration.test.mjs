import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const chatterboxImporter = path.join(repoRoot, 'scripts', 'import-roachvoice-chatterbox-coreml.mjs')

test('RoachVoice hydration fails clearly before any download when Core ML tooling is unavailable', { skip: process.platform === 'darwin' }, () => {
  assert.throws(
    () => execFileSync(process.execPath, [chatterboxImporter, '--check-compiler'], { cwd: repoRoot, encoding: 'utf8', stdio: 'pipe' }),
    (error) => {
      const output = `${error.stdout || ''}\n${error.stderr || ''}`
      assert.match(output, /requires Xcode Command Line Tools with coremlcompiler/)
      assert.match(output, /xcode-select --switch \/Applications\/Xcode\.app\/Contents\/Developer/)
      assert.doesNotMatch(output, /Cannot read properties of undefined/)
      return true
    }
  )
})

test('RoachSpeech importers default to immutable upstream revisions', () => {
  for (const script of [
    'import-roachvoice-chatterbox-coreml.mjs',
    'import-roachvoice-kokoro-coreml.mjs',
    'import-roachwhisper-coreml-from-whisperkit.mjs',
  ]) {
    const source = readFileSync(path.join(repoRoot, 'scripts', script), 'utf8')
    assert.match(source, /const defaultRevision = '[0-9a-f]{40}'/)
    assert.doesNotMatch(source, /revision[^\n]*: 'main'/)
  }
  const whisperSource = readFileSync(path.join(repoRoot, 'scripts', 'import-roachwhisper-coreml-from-whisperkit.mjs'), 'utf8')
  assert.match(whisperSource, /tokenizerRevisionMap/)
  assert.doesNotMatch(whisperSource, /resolve\/main\//)
})
