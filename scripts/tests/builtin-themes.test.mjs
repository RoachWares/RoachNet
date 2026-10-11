import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')

test('the compiled-in theme list matches native/macos/Themes', () => {
  const output = execFileSync(process.execPath, ['scripts/generate-builtin-themes.mjs', '--check'], { cwd: repoRoot, encoding: 'utf8' })
  assert.match(output, /Built-in themes are current: \d+ themes, \d+ snippets/)
})

test('1.1 ships at least thirty themes with original names and both modes covered', () => {
  const folder = path.join(repoRoot, 'native/macos/Themes/builtin')
  const themes = readdirSync(folder)
    .filter((name) => name.endsWith('.roachtheme.json'))
    .map((name) => JSON.parse(readFileSync(path.join(folder, name), 'utf8')))
  assert.ok(themes.length >= 30, `${themes.length} themes`)
  assert.ok(themes.filter((theme) => theme.light).length >= 10, 'at least ten light modes')
  assert.ok(themes.filter((theme) => theme.dark).length >= 20, 'at least twenty dark modes')
  assert.ok(themes.some((theme) => theme.tags?.includes('halloween')), 'a Halloween theme ships in the box')
  const taken = /dracula|nord\b|solarized|monokai|gruvbox|one dark|tokyo night|catppuccin|ros[eé] pine|everforest|\bayu\b|material|synthwave|abyss|cobalt|solar flare/i
  for (const theme of themes) {
    assert.doesNotMatch(theme.name, taken, `${theme.name} reuses a well-known theme name`)
    assert.equal(theme.author, 'RoachWares')
  }
})
