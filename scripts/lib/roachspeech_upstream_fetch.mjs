// Fetches the RoachSpeech packs' upstream files from Hugging Face (ROA-96).
//
// Every file comes from a pinned commit, and docs/release-gates/
// roachspeech-upstream-inputs.json records each one's size and digest: SHA-256
// for LFS files, git's blob id for the rest. A file is used only once its bytes
// match that record, whether it was just downloaded or found in the cache, so
// an incomplete, corrupted or substituted file is never accepted.
//
// Requests are retried a bounded number of times when the failure is
// transient: a dropped or stalled connection, or HTTP 408, 425, 429 or 5xx.
// Backoff is exponential with jitter, and Retry-After is honored up to five
// minutes; no request keeps trying for more than fifteen. Anything else fails
// at once. Failures throw DependencyFetchError, so callers
// can tell an upstream that couldn't be reached from a build or test failure.

import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { setTimeout as sleepMs } from 'node:timers/promises'

export const upstreamInputsSchema = 'org.roachnet.roachspeech-upstream-inputs.v1'

export class DependencyFetchError extends Error {
  constructor(message, { url = null, status = null, transient = false, cause } = {}) {
    super(message, cause ? { cause } : undefined)
    this.name = 'DependencyFetchError'
    this.url = url
    this.status = status
    this.transient = transient
  }
}

const transientStatuses = new Set([408, 425, 429, 500, 502, 503, 504])
const transientCodes = new Set([
  'ECONNRESET', 'ECONNREFUSED', 'ECONNABORTED', 'ETIMEDOUT', 'EPIPE', 'EAI_AGAIN', 'ENOTFOUND',
  'ENETUNREACH', 'ENETDOWN', 'EHOSTUNREACH', 'UND_ERR_SOCKET', 'UND_ERR_CONNECT_TIMEOUT',
  'UND_ERR_HEADERS_TIMEOUT', 'UND_ERR_BODY_TIMEOUT', 'UND_ERR_CLOSED',
])

export function isTransientStatus(status) {
  return transientStatuses.has(status)
}

/** A dropped, refused, reset or stalled connection, looking through `cause`. */
export function isTransientNetworkError(error) {
  for (let current = error, depth = 0; current && depth < 6; current = current.cause, depth += 1) {
    if (current instanceof DependencyFetchError) return current.transient
    if (current.name === 'TimeoutError' || current.name === 'AbortError') return true
    if (transientCodes.has(current.code)) return true
    if (/\b(terminated|fetch failed|socket hang up|other side closed)\b/i.test(current.message || '')) return true
  }
  return false
}

/** Retry-After in milliseconds (delta-seconds or an HTTP date), or null. */
export function parseRetryAfter(value, now = Date.now()) {
  if (value === null || value === undefined) return null
  const text = String(value).trim()
  if (/^\d+$/.test(text)) return Number(text) * 1000
  const at = Date.parse(text)
  return Number.isNaN(at) ? null : Math.max(0, at - now)
}

/** Exponential backoff with equal jitter: between half and all of the step's ceiling. */
export function backoffMs(attempt, { baseMs = 2_000, maxMs = 60_000, random = Math.random } = {}) {
  const ceiling = Math.min(maxMs, baseMs * 2 ** Math.max(0, attempt - 1))
  return Math.round(ceiling / 2 + random() * (ceiling / 2))
}

const defaults = {
  attempts: 6,
  baseMs: 2_000,
  maxMs: 60_000,
  maxRetryAfterMs: 300_000,
  budgetMs: 15 * 60_000,
  stallMs: 60_000,
  userAgent: 'RoachNet-RoachSpeech-Importer/2.0',
}

function settings(options = {}) {
  const env = process.env
  const number = (value, fallback) => {
    const parsed = Number(value)
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback
  }
  return {
    ...defaults,
    attempts: Math.max(1, Math.floor(number(env.ROACHNET_UPSTREAM_FETCH_ATTEMPTS, defaults.attempts))),
    fetchImpl: globalThis.fetch,
    sleep: sleepMs,
    random: Math.random,
    log: (message) => console.warn(message),
    ...options,
  }
}

function statusError(response, url) {
  const transient = isTransientStatus(response.status)
  return new DependencyFetchError(`${url} answered HTTP ${response.status}`, {
    url,
    status: response.status,
    transient,
  })
}

/**
 * Runs `operation(signal, attempt)` until it succeeds, a failure isn't
 * transient, or the attempts run out. The signal aborts when no bytes have
 * arrived for `stallMs`; the operation calls `signal.touch()` as data comes in.
 */
async function withRetries(url, options, operation) {
  const opts = settings(options)
  const started = Date.now()
  let lastError = null
  let used = 0
  for (let attempt = 1; attempt <= opts.attempts; attempt += 1) {
    used = attempt
    const controller = new AbortController()
    let timer = null
    const touch = () => {
      clearTimeout(timer)
      timer = setTimeout(() => controller.abort(new DependencyFetchError(`${url} stalled for ${opts.stallMs} ms`, { url, transient: true })), opts.stallMs)
    }
    const signal = controller.signal
    signal.touch = touch
    touch()
    try {
      return await operation(signal, attempt, opts)
    } catch (caught) {
      const error = signal.aborted && signal.reason instanceof DependencyFetchError ? signal.reason : caught
      const transient = error instanceof DependencyFetchError ? error.transient : isTransientNetworkError(error)
      lastError = error instanceof DependencyFetchError
        ? error
        : new DependencyFetchError(`${url} failed: ${error?.message || error}`, { url, transient, cause: error })
      if (!transient || attempt === opts.attempts) break
      let wait = backoffMs(attempt, opts)
      const retryAfter = lastError.retryAfterMs
      if (retryAfter !== null && retryAfter !== undefined) {
        if (retryAfter > opts.maxRetryAfterMs) {
          lastError = new DependencyFetchError(`${lastError.message}; Retry-After asks for ${Math.round(retryAfter / 1000)} s, more than the ${Math.round(opts.maxRetryAfterMs / 1000)} s allowed`, { url, status: lastError.status, transient: true })
          break
        }
        wait = Math.max(wait, retryAfter)
      }
      if (Date.now() - started + wait > opts.budgetMs) {
        lastError = new DependencyFetchError(`${lastError.message}; giving up after ${Math.round((Date.now() - started) / 1000)} s`, { url, status: lastError.status, transient: true })
        break
      }
      opts.log(`${lastError.message}; attempt ${attempt} of ${opts.attempts}, retrying in ${Math.round(wait / 100) / 10} s`)
      await opts.sleep(wait)
    } finally {
      clearTimeout(timer)
    }
  }
  throw new DependencyFetchError(`Couldn't fetch ${url} (${used} attempt${used === 1 ? '' : 's'}): ${lastError?.message}`, {
    url,
    status: lastError?.status ?? null,
    transient: lastError?.transient ?? false,
    cause: lastError,
  })
}

async function request(url, signal, opts) {
  const response = await opts.fetchImpl(url, { headers: { 'User-Agent': opts.userAgent }, redirect: 'follow', signal })
  if (!response.ok) {
    const error = statusError(response, url)
    error.retryAfterMs = parseRetryAfter(response.headers.get('retry-after'))
    await response.body?.cancel().catch(() => {})
    throw error
  }
  return response
}

export async function fetchJsonWithRetry(url, options = {}) {
  return withRetries(url, options, async (signal, _attempt, opts) => {
    const response = await request(url, signal, opts)
    signal.touch()
    return response.json()
  })
}

/** What a tree entry promises about a file's bytes. */
export function expectationFor(entry) {
  if (entry.lfs?.oid) return { bytes: entry.lfs.size, sha256: entry.lfs.oid }
  return { bytes: entry.size, gitBlobSha1: entry.oid }
}

function checkExpectation(expected, where) {
  const sizeOk = Number.isSafeInteger(expected?.bytes) && expected.bytes >= 0
  const digestOk = /^[0-9a-f]{64}$/.test(expected?.sha256 || '') || /^[0-9a-f]{40}$/.test(expected?.gitBlobSha1 || '')
  if (!sizeOk || !digestOk) throw new DependencyFetchError(`No usable size and digest recorded for ${where}.`, { transient: false })
}

function hashers(expected) {
  const sha256 = createHash('sha256')
  const blob = expected.gitBlobSha1 ? createHash('sha1').update(`blob ${expected.bytes}\0`) : null
  return {
    update(chunk) { sha256.update(chunk); blob?.update(chunk) },
    matches() {
      if (expected.sha256) return sha256.digest('hex') === expected.sha256
      return blob.digest('hex') === expected.gitBlobSha1
    },
  }
}

/** True when `filePath` is a regular file with exactly the expected bytes. */
export async function fileMatches(filePath, expected) {
  let info
  try {
    info = fs.lstatSync(filePath)
  } catch {
    return false
  }
  if (!info.isFile() || info.size !== expected.bytes) return false
  const hash = hashers(expected)
  for await (const chunk of fs.createReadStream(filePath)) hash.update(chunk)
  return hash.matches()
}

/**
 * Puts the file at `destination`, verified against `expected`. A verified copy
 * already there is reused; anything else there is replaced. The download goes
 * to a temporary file beside it and is renamed into place only once it
 * verifies. Returns 'cached' or 'downloaded'.
 */
export async function downloadVerified(url, destination, expected, options = {}) {
  checkExpectation(expected, url)
  if (await fileMatches(destination, expected)) return 'cached'
  fs.mkdirSync(path.dirname(destination), { recursive: true })
  const existing = fs.lstatSync(destination, { throwIfNoEntry: false })
  if (existing?.isDirectory()) throw new DependencyFetchError(`${destination} is a folder, not a file.`, { url, transient: false })
  const partial = `${destination}.partial-${process.pid}`
  try {
    return await withRetries(url, options, async (signal, _attempt, opts) => {
      fs.rmSync(partial, { force: true })
      const response = await request(url, signal, opts)
      const hash = hashers(expected)
      let received = 0
      const out = fs.openSync(partial, 'wx', 0o644)
      try {
        for await (const chunk of response.body) {
          signal.touch()
          received += chunk.length
          if (received > expected.bytes) {
            throw new DependencyFetchError(`${url} sent more than the ${expected.bytes} bytes the pinned commit records`, { url, transient: false })
          }
          hash.update(chunk)
          for (let offset = 0; offset < chunk.length;) offset += fs.writeSync(out, chunk, offset, chunk.length - offset)
        }
        fs.fsyncSync(out)
      } finally {
        fs.closeSync(out)
      }
      if (received < expected.bytes) {
        throw new DependencyFetchError(`${url} ended after ${received} of ${expected.bytes} bytes`, { url, transient: true })
      }
      if (!hash.matches()) {
        throw new DependencyFetchError(`${url} doesn't match the digest the pinned commit records`, { url, transient: false })
      }
      fs.renameSync(partial, destination)
      return 'downloaded'
    })
  } finally {
    fs.rmSync(partial, { force: true })
  }
}

export function huggingFaceFileURL(repository, revision, filePath) {
  return `https://huggingface.co/${repository}/resolve/${revision}/${filePath.split('/').map(encodeURIComponent).join('/')}`
}

export function upstreamKey({ repository, revision, subpath = '' }) {
  return `${repository}@${revision}${subpath ? `:${subpath}` : ''}`
}

export function readUpstreamInputs(manifestPath) {
  if (!fs.existsSync(manifestPath)) return null
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  if (manifest.schema !== upstreamInputsSchema || typeof manifest.trees !== 'object') {
    throw new Error(`${manifestPath} is not a ${upstreamInputsSchema} manifest.`)
  }
  return manifest
}

/** A recorded file, in the Hugging Face tree entry shape the importers use. */
function treeEntryFromRecord(record) {
  return record.sha256
    ? { type: 'file', path: record.path, size: record.bytes, lfs: { oid: record.sha256, size: record.bytes } }
    : { type: 'file', path: record.path, size: record.bytes, oid: record.gitBlobSha1 }
}

/**
 * The files of a pinned upstream tree. A commit recorded in the inputs
 * manifest is read from it, with no request; any other commit is listed by
 * the Hugging Face API, with retries.
 */
export async function listUpstreamFiles(source, { manifest = null, ...options } = {}) {
  const recorded = manifest?.trees?.[upstreamKey(source)]
  if (recorded) return recorded.map(treeEntryFromRecord)
  const { repository, revision, subpath = '' } = source
  const suffix = subpath ? `/${subpath.split('/').map(encodeURIComponent).join('/')}` : ''
  const url = `https://huggingface.co/api/models/${repository}/tree/${revision}${suffix}?recursive=1`
  const entries = await fetchJsonWithRetry(url, options)
  if (!Array.isArray(entries)) throw new DependencyFetchError(`${url} didn't answer with a file list`, { url, transient: false })
  return entries.filter((entry) => entry.type === 'file')
}

/** Where verified upstream files are kept between runs, by repository and commit. */
export function upstreamCacheRoot(repoRoot) {
  const configured = process.env.ROACHNET_ROACHSPEECH_UPSTREAM_CACHE?.trim()
  return configured ? path.resolve(configured) : path.join(repoRoot, '.tmp', 'roachspeech-upstream')
}

export function cachedUpstreamPath(cacheRoot, { repository, revision }, filePath) {
  const parts = filePath.split('/')
  if (!filePath || parts.some((part) => part === '' || part === '.' || part === '..')) {
    throw new DependencyFetchError(`Refusing upstream path ${JSON.stringify(filePath)}.`, { transient: false })
  }
  return path.join(cacheRoot, ...repository.split('/'), revision, ...parts)
}

/** Downloads (or reuses) one upstream file into the cache and returns its path. */
export async function fetchUpstreamFile(cacheRoot, source, entry, options = {}) {
  const destination = cachedUpstreamPath(cacheRoot, source, entry.path)
  await downloadVerified(huggingFaceFileURL(source.repository, source.revision, entry.path), destination, expectationFor(entry), options)
  return destination
}

/**
 * Exits the way CI can tell apart: 3 when an upstream couldn't be fetched or
 * didn't verify, 1 for anything else. Under GitHub Actions the dependency
 * failure is also annotated as one.
 */
export function exitForError(error) {
  const message = error instanceof Error ? error.message : String(error)
  if (error instanceof DependencyFetchError) {
    console.error(`Dependency download failed: ${message}`)
    if (process.env.GITHUB_ACTIONS === 'true') {
      const data = message.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A')
      console.error(`::error title=Dependency download failed::${data}`)
    }
    process.exit(3)
  }
  console.error(message)
  process.exit(1)
}
