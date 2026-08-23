import assert from 'node:assert/strict'
import test from 'node:test'

import { compareRelease } from '../audit-upstream-projects.mjs'

test('upstream release audit ignores sub-second timestamp precision changes', () => {
  assert.doesNotThrow(() => compareRelease(
    'esDe',
    {
      tag: 'v3.4.1',
      name: 'Version 3.4.1 / 3.4.1-58',
      publishedAt: '2026-04-10T12:12:41.297Z',
      commit: '5db4e2a32bd5852cc7a3dbeb298d85de86a536d7',
    },
    {
      tag: 'v3.4.1',
      name: 'Version 3.4.1 / 3.4.1-58',
      publishedAt: '2026-04-10T12:12:41.000Z',
      commit: '5db4e2a32bd5852cc7a3dbeb298d85de86a536d7',
    },
  ))
})
