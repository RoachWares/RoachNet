import assert from 'node:assert/strict'
import test from 'node:test'

import { auditTextForPublicRelease } from '../audit-public-release-surface.mjs'

const publisher = ['Cross', 'talk Solutions LLC'].join('')
const retainedUpstreamAttribution = `- Its retained copyright notice names ${publisher} for 2024–2026.`
const retainedLicenseAttribution = `   Copyright 2024-2026 ${publisher}`

test('dedicated upstream provenance and license may retain only their exact legal attribution lines', () => {
  assert.deepEqual(auditTextForPublicRelease('docs/UPSTREAM.md', retainedUpstreamAttribution), [])
  assert.deepEqual(auditTextForPublicRelease('LICENSE', retainedLicenseAttribution), [])
})

test('upstream publisher identity remains blocked outside the exact legal attribution lines', () => {
  for (const [file, contents] of [
    ['README.md', publisher],
    ['docs/UPSTREAM.md', publisher],
    ['LICENSE', publisher],
    ['docs/UPSTREAM.md', `${retainedUpstreamAttribution}\nhttps://${['crosstalk', 'solutions'].join('')}.example`],
  ]) {
    const failures = auditTextForPublicRelease(file, contents)
    assert.ok(failures.some((failure) => failure.includes('old imported upstream publisher identity') || failure.includes('old imported upstream community URL')))
  }
})

test('dedicated upstream provenance still rejects personal paths and private keys', () => {
  const privateKeyMarker = ['-----BEGIN ', 'PRIVATE KEY-----'].join('')
  const failures = auditTextForPublicRelease(
    'docs/UPSTREAM.md',
    `${retainedUpstreamAttribution}\n${['/Users/', 'roach/private'].join('')}\n${privateKeyMarker}`
  )
  assert.ok(failures.some((failure) => failure.includes('local user path')))
  assert.ok(failures.some((failure) => failure.includes('private key material')))
})
