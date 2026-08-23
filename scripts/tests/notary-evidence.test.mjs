import assert from 'node:assert/strict'
import test from 'node:test'

import { parseAcceptedNotarySubmission } from '../lib/roachnet_notary_evidence.mjs'

test('notary submission evidence records exact candidate artifact ID and Accepted status', () => {
  assert.deepEqual(
    parseAcceptedNotarySubmission(
      JSON.stringify({
        id: '11111111-2222-3333-4444-555555555555',
        status: 'Accepted',
        message: 'Processing complete',
      }),
      '/tmp/RoachNet-Setup-macOS.dmg'
    ),
    {
      artifact: 'RoachNet-Setup-macOS.dmg',
      submissionId: '11111111-2222-3333-4444-555555555555',
      status: 'Accepted',
    }
  )
})

test('notary submission evidence fails closed on malformed or non-Accepted output', () => {
  assert.throws(
    () => parseAcceptedNotarySubmission('{"id":"bad","status":"Accepted"}', '/tmp/RoachNet.dmg'),
    /submission ID is invalid/i
  )
  assert.throws(
    () => parseAcceptedNotarySubmission('{"id":"11111111-2222-3333-4444-555555555555","status":"Invalid"}', '/tmp/RoachNet.dmg'),
    /did not return Accepted/i
  )
})
