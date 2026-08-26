import assert from 'node:assert/strict'
import test from 'node:test'

import {
  assertCompanionBindHost,
  buildUpstreamCompanionUrl,
  isCompanionProxyPath,
  resolveCompanionTargetOrigin,
  sanitizeUserFacingHost,
} from '../lib/roachnet_companion_security.mjs'

test('resolveCompanionTargetOrigin only allows loopback desktop runtime origins', () => {
  assert.equal(resolveCompanionTargetOrigin('http://127.0.0.1:8080/home'), 'http://127.0.0.1:8080')
  assert.equal(resolveCompanionTargetOrigin('https://localhost:8443'), 'https://localhost:8443')
  assert.equal(resolveCompanionTargetOrigin('http://[::1]:8080'), 'http://[::1]:8080')

  assert.throws(() => resolveCompanionTargetOrigin('http://0.0.0.0:8080'), /local desktop runtime/)
  assert.throws(() => resolveCompanionTargetOrigin('http://192.168.1.20:8080'), /local desktop runtime/)
  assert.throws(() => resolveCompanionTargetOrigin('file:///tmp/runtime.sock'), /http or https/)
  assert.throws(() => resolveCompanionTargetOrigin('http://user:pass@127.0.0.1:8080'), /credentials/)
})

test('assertCompanionBindHost only allows loopback listener addresses', () => {
  for (const host of ['127.0.0.1', 'localhost', '::1', '[::1]', '::ffff:127.0.0.1']) {
    assert.equal(assertCompanionBindHost(host), host)
  }

  for (const host of ['', '0.0.0.0', '::', '192.168.1.20', '10.0.0.5', 'example.test']) {
    assert.throws(() => assertCompanionBindHost(host), /must bind only to a loopback address/)
  }
})

test('buildUpstreamCompanionUrl preserves only the companion API path family', () => {
  const targetOrigin = 'http://127.0.0.1:8080'
  assert.equal(
    buildUpstreamCompanionUrl(
      new URL('http://roachnet-companion.local/api/companion/roachtail?mode=pair'),
      targetOrigin
    ).toString(),
    'http://127.0.0.1:8080/api/companion/roachtail?mode=pair'
  )
  assert.equal(
    buildUpstreamCompanionUrl(new URL('http://roachnet-companion.local/api/companion'), targetOrigin).toString(),
    'http://127.0.0.1:8080/api/companion'
  )

  assert.throws(
    () => buildUpstreamCompanionUrl(new URL('http://roachnet-companion.local/api/companionevil'), targetOrigin),
    /Unsupported companion proxy path/
  )
  assert.throws(
    () => buildUpstreamCompanionUrl(new URL('http://roachnet-companion.local//api/companion'), targetOrigin),
    /Unsupported companion proxy path/
  )
  assert.throws(
    () => buildUpstreamCompanionUrl(new URL('http://roachnet-companion.local/api/companion'), 'https://example.com'),
    /local desktop runtime/
  )
})

test('isCompanionProxyPath only accepts the exact companion API family', () => {
  assert.equal(isCompanionProxyPath('/api/companion'), true)
  assert.equal(isCompanionProxyPath('/api/companion/roachtail'), true)
  assert.equal(isCompanionProxyPath('/api/companionevil'), false)
  assert.equal(isCompanionProxyPath('//api/companion'), false)
})

test('sanitizeUserFacingHost redacts local and numeric hosts from peer state', () => {
  assert.equal(sanitizeUserFacingHost('http://localhost:38111', 'RoachNet'), 'RoachNet')
  assert.equal(sanitizeUserFacingHost('192.168.1.44:38111', 'RoachNet'), 'RoachNet')
  assert.equal(sanitizeUserFacingHost('[::1]:38111', 'RoachNet'), 'RoachNet')
  assert.equal(sanitizeUserFacingHost('roachnet.example.test:38111', 'RoachNet'), 'roachnet.example.test:38111')
})
