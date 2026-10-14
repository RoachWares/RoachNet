import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  DependencyFetchError,
  backoffMs,
  cachedUpstreamPath,
  downloadVerified,
  expectationFor,
  isTransientNetworkError,
  isTransientStatus,
  listUpstreamFiles,
  parseRetryAfter,
  readUpstreamInputs,
  upstreamKey,
} from '../lib/roachspeech_upstream_fetch.mjs'
import { roachSpeechUpstreams } from '../roachspeech-pack-digests.mjs'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const body = Buffer.from('pinned upstream bytes\n'.repeat(64))
const sha256 = createHash('sha256').update(body).digest('hex')
const blobSha1 = createHash('sha1').update(`blob ${body.length}\0`).update(body).digest('hex')
const lfs = { bytes: body.length, sha256 }

/** A local server whose n-th request (from 0) is answered by `steps[n]` (the last one repeats). */
async function serve(steps) {
  const requests = []
  const server = http.createServer((request, response) => {
    const index = Math.min(requests.length, steps.length - 1)
    requests.push(request.url)
    steps[index](request, response)
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  const url = `http://127.0.0.1:${server.address().port}/file.bin`
  return { url, requests, close: () => new Promise((resolve) => { server.closeAllConnections(); server.close(resolve) }) }
}

const ok = (payload = body) => (_request, response) => {
  response.writeHead(200, { 'content-length': payload.length })
  response.end(payload)
}
const status = (code, headers = {}) => (_request, response) => {
  response.writeHead(code, { 'content-length': 0, ...headers })
  response.end()
}
const truncated = (_request, response) => {
  response.writeHead(200, { 'content-length': body.length })
  response.write(body.subarray(0, 100))
  setTimeout(() => response.socket.destroy(), 10)
}
const stalls = (_request, response) => {
  response.writeHead(200, { 'content-length': body.length })
  response.write(body.subarray(0, 10))
}

function workdir() {
  return mkdtempSync(path.join(os.tmpdir(), 'roachspeech-fetch-'))
}

function quiet(waits = []) {
  return { sleep: async (ms) => { waits.push(ms) }, log: () => {}, random: () => 0.5, baseMs: 10, maxMs: 40 }
}

function leftovers(directory) {
  return readdirSync(directory).filter((name) => name.includes('.partial-'))
}

test('Retry-After, backoff and transient classification (ROA-96)', () => {
  assert.equal(parseRetryAfter('7'), 7000)
  const now = Date.parse('2026-10-14T00:00:00Z')
  assert.equal(parseRetryAfter('Wed, 14 Oct 2026 00:00:30 GMT', now), 30_000)
  assert.equal(parseRetryAfter('Tue, 13 Oct 2026 23:00:00 GMT', now), 0)
  assert.equal(parseRetryAfter('soon'), null)
  assert.equal(parseRetryAfter(null), null)

  for (let attempt = 1; attempt <= 12; attempt += 1) {
    const ceiling = Math.min(60_000, 2_000 * 2 ** (attempt - 1))
    for (const draw of [0, 0.5, 0.999]) {
      const wait = backoffMs(attempt, { random: () => draw })
      assert.ok(wait >= ceiling / 2 && wait <= ceiling, `attempt ${attempt}: ${wait} not in [${ceiling / 2}, ${ceiling}]`)
    }
  }

  for (const code of [408, 425, 429, 500, 502, 503, 504]) assert.ok(isTransientStatus(code), String(code))
  for (const code of [400, 401, 403, 404, 410, 416, 451]) assert.ok(!isTransientStatus(code), String(code))
  assert.ok(isTransientNetworkError(new TypeError('fetch failed', { cause: Object.assign(new Error('read'), { code: 'ECONNRESET' }) })))
  assert.ok(isTransientNetworkError(new TypeError('terminated')))
  assert.ok(isTransientNetworkError(Object.assign(new Error('timed out'), { name: 'TimeoutError' })))
  assert.ok(!isTransientNetworkError(new Error('ENOSPC: no space left on device')))
})

test('a 429 is retried after its Retry-After, and the file lands only once it verifies', async () => {
  const dir = workdir()
  const server = await serve([status(429, { 'retry-after': '1' }), status(503), ok()])
  try {
    const waits = []
    const destination = path.join(dir, 'file.bin')
    assert.equal(await downloadVerified(server.url, destination, lfs, quiet(waits)), 'downloaded')
    assert.deepEqual(readFileSync(destination), body)
    assert.equal(server.requests.length, 3)
    assert.ok(waits[0] >= 1000, `waited ${waits[0]} ms after Retry-After: 1`)
    assert.deepEqual(leftovers(dir), [])
  } finally {
    await server.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('retries are bounded, and a permanent error is not retried', async () => {
  const dir = workdir()
  const failing = await serve([status(500)])
  const missing = await serve([status(404)])
  try {
    const destination = path.join(dir, 'file.bin')
    await assert.rejects(downloadVerified(failing.url, destination, lfs, { ...quiet(), attempts: 3 }), (error) => {
      assert.ok(error instanceof DependencyFetchError)
      assert.equal(error.transient, true)
      assert.equal(error.status, 500)
      assert.match(error.message, /3 attempts/)
      return true
    })
    assert.equal(failing.requests.length, 3)
    await assert.rejects(downloadVerified(missing.url, destination, lfs, quiet()), (error) => {
      assert.ok(error instanceof DependencyFetchError)
      assert.equal(error.transient, false)
      assert.equal(error.status, 404)
      return true
    })
    assert.equal(missing.requests.length, 1)
    assert.ok(!existsSync(destination))
    assert.deepEqual(leftovers(dir), [])
  } finally {
    await failing.close()
    await missing.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a Retry-After beyond the cap, or past the time budget, fails instead of waiting', async () => {
  const dir = workdir()
  const server = await serve([status(429, { 'retry-after': '3600' })])
  const busy = await serve([status(429, { 'retry-after': '1' })])
  try {
    const waits = []
    await assert.rejects(downloadVerified(server.url, path.join(dir, 'file.bin'), lfs, quiet(waits)), /Retry-After asks for 3600 s/)
    assert.equal(server.requests.length, 1)
    await assert.rejects(downloadVerified(busy.url, path.join(dir, 'file.bin'), lfs, { ...quiet(waits), budgetMs: 500 }), /giving up after/)
    assert.equal(busy.requests.length, 1)
    assert.deepEqual(waits, [])
  } finally {
    await server.close()
    await busy.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('an incomplete, oversized or substituted download is never accepted', async () => {
  const dir = workdir()
  const cut = await serve([truncated, ok()])
  const wrong = await serve([ok(Buffer.alloc(body.length, 0x41))])
  const big = await serve([ok(Buffer.concat([body, Buffer.from('x')]))])
  try {
    const destination = path.join(dir, 'file.bin')
    assert.equal(await downloadVerified(cut.url, destination, lfs, quiet()), 'downloaded')
    assert.equal(cut.requests.length, 2, 'a connection cut mid-body is retried')
    assert.deepEqual(readFileSync(destination), body)
    rmSync(destination)

    await assert.rejects(downloadVerified(wrong.url, destination, lfs, quiet()), (error) => error instanceof DependencyFetchError && !error.transient && /digest/.test(error.message))
    assert.equal(wrong.requests.length, 1, 'a digest mismatch is not retried')
    assert.ok(!existsSync(destination))
    await assert.rejects(downloadVerified(big.url, destination, lfs, quiet()), /more than the \d+ bytes/)
    assert.ok(!existsSync(destination))
    assert.deepEqual(leftovers(dir), [])
  } finally {
    await cut.close()
    await wrong.close()
    await big.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('a stalled transfer is cut off and retried', async () => {
  const dir = workdir()
  const server = await serve([stalls, ok()])
  try {
    const destination = path.join(dir, 'file.bin')
    assert.equal(await downloadVerified(server.url, destination, lfs, { ...quiet(), stallMs: 200 }), 'downloaded')
    assert.equal(server.requests.length, 2)
    assert.deepEqual(readFileSync(destination), body)
  } finally {
    await server.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('the cache is used only when its copy verifies', async () => {
  const dir = workdir()
  const server = await serve([ok()])
  try {
    const destination = path.join(dir, 'file.bin')
    writeFileSync(destination, body)
    assert.equal(await downloadVerified(server.url, destination, lfs, quiet()), 'cached')
    assert.equal(await downloadVerified(server.url, destination, { bytes: body.length, gitBlobSha1: blobSha1 }, quiet()), 'cached')
    assert.equal(server.requests.length, 0)

    writeFileSync(destination, Buffer.alloc(body.length, 0x42))
    assert.equal(await downloadVerified(server.url, destination, lfs, quiet()), 'downloaded')
    assert.deepEqual(readFileSync(destination), body)
    assert.equal(server.requests.length, 1)

    await assert.rejects(downloadVerified(server.url, destination, { bytes: body.length }, quiet()), /No usable size and digest/)
    mkdirSync(path.join(dir, 'folder'))
    await assert.rejects(downloadVerified(server.url, path.join(dir, 'folder'), lfs, quiet()), /is a folder/)
  } finally {
    await server.close()
    rmSync(dir, { recursive: true, force: true })
  }
})

test('recorded trees are read without a request, and cache paths stay inside the cache', async () => {
  const source = { repository: 'org/repo', revision: 'a'.repeat(40) }
  const manifest = {
    trees: {
      [upstreamKey(source)]: [
        { path: 'model.bin', bytes: 3, sha256: 'b'.repeat(64) },
        { path: 'README.md', bytes: 5, gitBlobSha1: 'c'.repeat(40) },
      ],
    },
  }
  let requests = 0
  const files = await listUpstreamFiles(source, { manifest, fetchImpl: async () => { requests += 1; throw new Error('no network') } })
  assert.equal(requests, 0)
  assert.deepEqual(files.map(expectationFor), [
    { bytes: 3, sha256: 'b'.repeat(64) },
    { bytes: 5, gitBlobSha1: 'c'.repeat(40) },
  ])
  assert.equal(cachedUpstreamPath('/cache', source, 'a/b.bin'), path.join('/cache', 'org', 'repo', 'a'.repeat(40), 'a', 'b.bin'))
  for (const bad of ['../x', 'a/../../x', '/abs', 'a//b', '.', '']) {
    assert.throws(() => cachedUpstreamPath('/cache', source, bad), /Refusing upstream path/, bad)
  }
})

test('every pinned RoachSpeech commit has its files recorded with sizes and digests', () => {
  const manifest = readUpstreamInputs(path.join(repoRoot, 'docs', 'release-gates', 'roachspeech-upstream-inputs.json'))
  assert.ok(manifest, 'docs/release-gates/roachspeech-upstream-inputs.json is missing')
  const pinned = new Set(Object.values(roachSpeechUpstreams).flat().map(({ repository, revision }) => `${repository}@${revision}`))
  const recorded = new Set(Object.keys(manifest.trees).map((key) => key.split(':')[0]))
  for (const commit of pinned) assert.ok(recorded.has(commit), `${commit} has no recorded files`)
  for (const [key, files] of Object.entries(manifest.trees)) {
    assert.ok(files.length > 0, key)
    for (const file of files) {
      assert.ok(Number.isSafeInteger(file.bytes) && file.bytes >= 0, `${key}:${file.path}`)
      assert.ok(/^[0-9a-f]{64}$/.test(file.sha256 || '') || /^[0-9a-f]{40}$/.test(file.gitBlobSha1 || ''), `${key}:${file.path}`)
      assert.doesNotThrow(() => cachedUpstreamPath('/cache', { repository: 'o/r', revision: 'x' }, file.path), `${key}:${file.path}`)
    }
  }
})
