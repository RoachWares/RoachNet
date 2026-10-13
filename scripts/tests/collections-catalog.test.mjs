import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// The bundled Kiwix catalog: "Download recommended" queues the recommended
// tier, so it must hold something that can actually download, and a
// resource's version must name the ZIM its URL points at.
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const catalog = JSON.parse(readFileSync(path.join(repoRoot, 'collections', 'kiwix-categories.json'), 'utf8'))

test('every category recommends a tier with something to download', () => {
  for (const category of catalog.categories) {
    const recommended = category.tiers.filter((tier) => tier.recommended)
    assert.equal(recommended.length, 1, `${category.slug} recommends one tier`)
    const available = recommended[0].resources.filter((resource) => !resource.unavailable)
    assert.ok(available.length > 0, `${category.slug}/${recommended[0].slug} has an available resource`)
  }
})

test('resource versions match the ZIM their URL names', () => {
  for (const category of catalog.categories) {
    for (const tier of category.tiers) {
      for (const resource of tier.resources) {
        const dated = /_(\d{4}-\d{2})[a-z]?\.zim$/.exec(resource.url || '')
        if (dated && resource.version) assert.equal(resource.version, dated[1], `${category.slug}/${resource.id}`)
      }
    }
  }
})
