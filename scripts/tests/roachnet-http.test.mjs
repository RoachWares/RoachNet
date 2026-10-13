import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { downloadHttpToFile, requestHttp, requestLocalRuntimeHttp } from '../lib/roachnet_http.mjs'

async function withServer(handler, callback) {
  const server = createServer(handler)
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })

  try {
    const address = server.address()
    assert.equal(typeof address, 'object')
    await callback(`http://127.0.0.1:${address.port}`)
  } finally {
    await new Promise((resolve) => server.close(resolve))
  }
}

test('requestHttp reads JSON and follows redirects without global fetch', async () => {
  await withServer((request, response) => {
    if (request.url === '/redirect') {
      response.writeHead(302, { Location: '/payload' })
      response.end()
      return
    }

    response.writeHead(200, { 'Content-Type': 'application/json' })
    response.end(JSON.stringify({ ok: true, path: request.url }))
  }, async (baseUrl) => {
    const response = await requestHttp(`${baseUrl}/redirect`, {
      headers: { Accept: 'application/json' },
    })

    assert.equal(response.ok, true)
    assert.deepEqual(await response.json(), { ok: true, path: '/payload' })
  })
})

test('requestHttp enforces response size limits', async () => {
  await withServer((_request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/plain' })
    response.end('x'.repeat(64))
  }, async (baseUrl) => {
    await assert.rejects(
      () => requestHttp(`${baseUrl}/large`, { maxResponseBytes: 8 }),
      /exceeded 8 bytes/
    )
  })
})

test('downloadHttpToFile streams response to disk', async () => {
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), 'roachnet-http-test-'))
  try {
    await withServer((_request, response) => {
      response.writeHead(200, { 'Content-Type': 'application/octet-stream' })
      response.end('native runtime payload')
    }, async (baseUrl) => {
      const destination = path.join(tempRoot, 'payload.bin')
      await downloadHttpToFile(`${baseUrl}/payload.bin`, destination)
      assert.equal(readFileSync(destination, 'utf8'), 'native runtime payload')
    })
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
})

test('downloadHttpToFile uses an atomic partial file and cleans failed downloads', async () => {
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), 'roachnet-http-atomic-test-'))
  try {
    await withServer((_request, response) => {
      response.writeHead(200, {
        'Content-Type': 'application/octet-stream',
        'Content-Length': '64',
      })
      response.end('x'.repeat(64))
    }, async (baseUrl) => {
      const destination = path.join(tempRoot, 'oversized.bin')
      await assert.rejects(
        () => downloadHttpToFile(`${baseUrl}/oversized.bin`, destination, { maxDownloadBytes: 8 }),
        /exceeded 8 bytes/
      )
      assert.equal(existsSync(destination), false)
      assert.equal(existsSync(`${destination}.part`), false)
    })
  } finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
})

test('requestLocalRuntimeHttp only calls loopback origins', async () => {
  await withServer((_request, response) => {
    response.writeHead(200, { 'Content-Type': 'application/json' })
    response.end(JSON.stringify({ ok: true }))
  }, async (baseUrl) => {
    const response = await requestLocalRuntimeHttp(`${baseUrl}/api/companion/bootstrap`)
    assert.equal(response.ok, true)
    assert.deepEqual(await response.json(), { ok: true })
  })

  await assert.rejects(
    () => requestLocalRuntimeHttp('https://example.com/api/companion/bootstrap'),
    /local desktop runtime/
  )
  await assert.rejects(
    () => requestLocalRuntimeHttp('http://user:secret@127.0.0.1:9/api/health'),
    /credentials/
  )

  // A redirect is never followed, so the local runtime can't send the request elsewhere.
  await withServer((_request, response) => {
    response.writeHead(302, { Location: 'https://example.com/elsewhere' })
    response.end()
  }, async (baseUrl) => {
    await assert.rejects(() => requestLocalRuntimeHttp(`${baseUrl}/api/health`), /Too many redirects/)
  })
})
