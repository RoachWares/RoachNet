import assert from 'node:assert/strict'
import test from 'node:test'

import { runCommand } from '../lib/roachnet_child_process.mjs'

test('runCommand reports a missing executable without an unhandled child error event', async () => {
  await assert.rejects(
    () => runCommand('roachnet-command-that-does-not-exist', []),
    /Unable to start roachnet-command-that-does-not-exist: .*ENOENT/
  )
})
