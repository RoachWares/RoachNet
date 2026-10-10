#!/usr/bin/env node

import { spawn, spawnSync } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { lookup } from 'node:dns/promises'
import { chmodSync, closeSync, constants as fsConstants, createReadStream, createWriteStream, existsSync, fstatSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, readdirSync, realpathSync, renameSync, writeFileSync, rmSync, statSync } from 'node:fs'
import { appendFile } from 'node:fs/promises'
import http from 'node:http'
import { isIP } from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { once } from 'node:events'
import { fileURLToPath } from 'node:url'
import {
  createRoachClawAgentRun,
  roachClawNativeAgentStatus,
} from './lib/roachnet_roachclaw_agent.mjs'
import { createAsyncTTLCache } from './lib/roachnet_async_cache.mjs'
import { declaresJsonBody, loopbackRequestRejection } from './lib/roachnet_loopback_guard.mjs'

const __filename = fileURLToPath(import.meta.url)
const repoRoot = path.resolve(path.dirname(__filename), '..')
const packageJson = JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8'))
const storageRoot = normalizePath(process.env.ROACHNET_STORAGE_PATH, path.join(os.homedir(), 'RoachNet', 'storage'))
const runtimeStateRoot = normalizePath(process.env.ROACHNET_RUNTIME_STATE_ROOT, path.join(storageRoot, '.runtime'))
const logRoot = path.join(storageRoot, 'logs')
const logPath = path.join(logRoot, 'roachnet-native-api.log')
const statePath = path.join(runtimeStateRoot, 'roachnet-native-api-state.json')
const processInfoPath = path.join(logRoot, 'roachnet-runtime-processes.json')
const roachTailStatePath = path.join(runtimeStateRoot, 'roachtail', 'state.json')
const legacyRoachTailStatePath = path.join(storageRoot, 'vault', 'roachtail', 'state.json')
const roachClawStateRoot = path.join(runtimeStateRoot, 'roachclaw')
const legacyRoachClawStateRoot = path.join(storageRoot, 'vault', 'roachclaw')
const ROACHTAIL_JOIN_CODE_TTL_MS = positiveIntegerEnv('ROACHTAIL_JOIN_CODE_TTL_MS', 10 * 60 * 1000)
const ROACHTAIL_AUTH_KEY_TTL_MS = positiveIntegerEnv('ROACHTAIL_AUTH_KEY_TTL_MS', 24 * 60 * 60 * 1000)
const ollamaBaseUrl = process.env.OLLAMA_BASE_URL || 'http://127.0.0.1:36434'
const openClawBaseUrl = process.env.OPENCLAW_BASE_URL || 'http://127.0.0.1:13001'
const defaultModel = process.env.ROACHNET_ROACHCLAW_DEFAULT_MODEL || 'qwen2.5-coder:1.5b'
const githubReleasesApiUrl =
  process.env.ROACHNET_GITHUB_RELEASES_API_URL?.trim() ||
  'https://api.github.com/repos/RoachWares/RoachNet/releases'
const githubReleasesUrl =
  process.env.ROACHNET_RELEASES_URL?.trim() ||
  'https://github.com/RoachWares/RoachNet/releases'
const appsDownloadsBaseUrl =
  process.env.ROACHNET_APPS_DOWNLOADS_BASE_URL?.trim() ||
  'https://apps.roachnet.org/downloads'
const roachClawReferenceRepository =
  process.env.ROACHNET_ROACHCLAW_REFERENCE_REPOSITORY?.trim() ||
  'https://github.com/pewdiepie-archdaemon/odysseus'
const roachClawReferenceCommit =
  process.env.ROACHNET_ROACHCLAW_REFERENCE_COMMIT?.trim() ||
  'd9ebdd6fbba31b5f3c2cbae90f650f183958660e'
const roachClawReferenceLatestCommit =
  process.env.ROACHNET_ROACHCLAW_REFERENCE_LATEST_COMMIT?.trim() ||
  roachClawReferenceCommit
const NATIVE_API_MAX_REQUEST_BODY_BYTES = positiveIntegerEnv('ROACHNET_NATIVE_API_MAX_BODY_BYTES', 1024 * 1024)
const NATIVE_API_DOWNLOAD_TIMEOUT_MS = positiveIntegerEnv('ROACHNET_NATIVE_API_DOWNLOAD_TIMEOUT_MS', 10 * 60 * 1000)
const NATIVE_API_MAX_DOWNLOAD_BYTES = positiveIntegerEnv('ROACHNET_NATIVE_API_MAX_DOWNLOAD_BYTES', 512 * 1024 ** 3)
const ROACHNET_SERVICE_HEALTH_PROBE_TIMEOUT_MS = positiveIntegerEnv('ROACHNET_SERVICE_HEALTH_PROBE_TIMEOUT_MS', 1_500)
const ROACHNET_RUNTIME_PROBE_CACHE_MS = positiveIntegerEnv('ROACHNET_RUNTIME_PROBE_CACHE_MS', 1_000)
const ROACHNET_CHAT_UPLOAD_MAX_BYTES = positiveIntegerEnv('ROACHNET_CHAT_UPLOAD_MAX_BYTES', 10 * 1024 * 1024)
const ROACHNET_GALLERY_UPLOAD_MAX_BYTES = positiveIntegerEnv('ROACHNET_GALLERY_UPLOAD_MAX_BYTES', 100 * 1024 * 1024)
const ROACHNET_GALLERY_TRANSFORM_UPLOAD_MAX_BYTES = positiveIntegerEnv('ROACHNET_GALLERY_TRANSFORM_UPLOAD_MAX_BYTES', 25 * 1024 * 1024)
const ROACHNET_VAULT_IMPORT_MAX_BYTES = positiveIntegerEnv('ROACHNET_VAULT_IMPORT_MAX_BYTES', 25 * 1024 * 1024)
const ROACHNET_MEMORY_IMPORT_MAX_BYTES = positiveIntegerEnv('ROACHNET_MEMORY_IMPORT_MAX_BYTES', 10 * 1024 * 1024)
const ROACHNET_EMAIL_ATTACHMENT_MAX_BYTES = positiveIntegerEnv('ROACHNET_EMAIL_ATTACHMENT_MAX_BYTES', 25 * 1024 * 1024)
const ROACHNET_STT_AUDIO_MAX_BYTES = positiveIntegerEnv('ROACHNET_STT_AUDIO_MAX_BYTES', 25 * 1024 * 1024)
const ROACHNET_CALENDAR_IMPORT_MAX_BYTES = positiveIntegerEnv('ROACHNET_CALENDAR_IMPORT_MAX_BYTES', 10 * 1024 * 1024)
const ROACHNET_UPLOAD_LIMIT_POLICIES = Object.freeze([
  { id: 'json-body', label: 'JSON request body', lane: 'native-api', env: 'ROACHNET_NATIVE_API_MAX_BODY_BYTES', bytes: NATIVE_API_MAX_REQUEST_BODY_BYTES, enforcement: 'readRequestBody' },
  { id: 'chat-upload', label: 'Chat attachment', lane: 'roachclaw-chat', env: 'ROACHNET_CHAT_UPLOAD_MAX_BYTES', bytes: ROACHNET_CHAT_UPLOAD_MAX_BYTES, enforcement: 'chat-file-intake' },
  { id: 'gallery-upload', label: 'Gallery import', lane: 'vault-gallery', env: 'ROACHNET_GALLERY_UPLOAD_MAX_BYTES', bytes: ROACHNET_GALLERY_UPLOAD_MAX_BYTES, enforcement: 'vault-media-intake' },
  { id: 'gallery-transform', label: 'Gallery transform input', lane: 'vault-gallery', env: 'ROACHNET_GALLERY_TRANSFORM_UPLOAD_MAX_BYTES', bytes: ROACHNET_GALLERY_TRANSFORM_UPLOAD_MAX_BYTES, enforcement: 'image-transform-intake' },
  { id: 'vault-import', label: 'Vault file import', lane: 'vault', env: 'ROACHNET_VAULT_IMPORT_MAX_BYTES', bytes: ROACHNET_VAULT_IMPORT_MAX_BYTES, enforcement: 'drag-drop-vault-intake' },
  { id: 'memory-import', label: 'Memory import', lane: 'roachbrain', env: 'ROACHNET_MEMORY_IMPORT_MAX_BYTES', bytes: ROACHNET_MEMORY_IMPORT_MAX_BYTES, enforcement: 'memory-provider-intake' },
  { id: 'email-attachment', label: 'Email attachment', lane: 'roachclaw-mail', env: 'ROACHNET_EMAIL_ATTACHMENT_MAX_BYTES', bytes: ROACHNET_EMAIL_ATTACHMENT_MAX_BYTES, enforcement: 'mail-compose-intake' },
  { id: 'speech-audio', label: 'RoachSpeech audio', lane: 'roachspeech', env: 'ROACHNET_STT_AUDIO_MAX_BYTES', bytes: ROACHNET_STT_AUDIO_MAX_BYTES, enforcement: 'speech-transcript-intake' },
  { id: 'calendar-import', label: 'Calendar import', lane: 'roachclaw-calendar', env: 'ROACHNET_CALENDAR_IMPORT_MAX_BYTES', bytes: ROACHNET_CALENDAR_IMPORT_MAX_BYTES, enforcement: 'ics-import-intake' },
  { id: 'download', label: 'Download job', lane: 'installer-app-store', env: 'ROACHNET_NATIVE_API_MAX_DOWNLOAD_BYTES', bytes: NATIVE_API_MAX_DOWNLOAD_BYTES, enforcement: 'download-to-partial-file' },
  { id: 'timeout', label: 'Download timeout', lane: 'installer-app-store', env: 'ROACHNET_NATIVE_API_DOWNLOAD_TIMEOUT_MS', milliseconds: NATIVE_API_DOWNLOAD_TIMEOUT_MS, enforcement: 'download-timeout' },
])
let benchmarkStatus = { status: 'idle', benchmarkId: null }
let systemUpdateStatus = updateStatus('idle', 0, 'No update in progress')
let latestReleaseCache = null
let ollamaProcess = null
let companionProcess = null
let downloadJobs = []
const runtimeReachabilityCache = createAsyncTTLCache(
  async (url) => {
    try {
      await fetchJson(url, { timeout: ROACHNET_SERVICE_HEALTH_PROBE_TIMEOUT_MS })
      return true
    } catch {
      return false
    }
  },
  { ttlMs: ROACHNET_RUNTIME_PROBE_CACHE_MS }
)
const installedModelsCache = createAsyncTTLCache(
  async (baseUrl) => {
    const tags = await fetchJson(new URL('/api/tags', baseUrl).toString(), { timeout: 2_500 })
    return (tags.models || []).map((model) => ({
      name: model.name,
      size: model.size || null,
    }))
  },
  { ttlMs: ROACHNET_RUNTIME_PROBE_CACHE_MS }
)

mkdirSync(logRoot, { recursive: true })
mkdirSync(runtimeStateRoot, { recursive: true })

if (process.argv.includes('--stop')) {
  await stopExistingRuntime()
  process.exit(0)
}

function normalizePath(value, fallback) {
  const trimmed = String(value || '').trim()
  return trimmed ? path.resolve(trimmed.replace(/^~(?=$|\/)/, os.homedir())) : fallback
}

function positiveIntegerEnv(name, fallback) {
  const value = Number(process.env[name])
  return Number.isSafeInteger(value) && value > 0 ? value : fallback
}

class NativeApiRequestError extends Error {
  constructor(message, statusCode = 400) {
    super(message)
    this.statusCode = statusCode
  }
}

async function log(line) {
  await appendFile(logPath, `[${new Date().toISOString()}] ${line}\n`).catch(() => {})
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function normalizeLoopbackHost(value) {
  const rawHost = String(value || '').trim().replace(/^\[|\]$/g, '')
  if (!rawHost || rawHost === '0.0.0.0' || rawHost === '::') {
    return '127.0.0.1'
  }
  if (['127.0.0.1', 'localhost', '::1'].includes(rawHost.toLowerCase())) {
    return rawHost
  }

  throw new Error(`RoachNet native API only binds to loopback hosts. Refusing HOST=${rawHost}.`)
}

function commandForPid(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) {
    return ''
  }

  const result = spawnSync('ps', ['-p', String(pid), '-o', 'command='], {
    encoding: 'utf8',
    timeout: 1_000,
  })
  return result.status === 0 ? String(result.stdout || '').trim() : ''
}

function commandLooksLikeRoachNetProcess(command, allowedNames) {
  if (!command) {
    return false
  }

  return allowedNames.some((name) => command.includes(name))
}

function pidIsAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function waitForPidExit(pid, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (!pidIsAlive(pid)) {
      return true
    }
    await sleep(150)
  }
  return false
}

async function terminateStatePid(pid, allowedNames, label) {
  if (!Number.isSafeInteger(pid) || pid <= 0 || pid === process.pid || !pidIsAlive(pid)) {
    return
  }

  const command = commandForPid(pid)
  if (!commandLooksLikeRoachNetProcess(command, allowedNames)) {
    await log(`skipped ${label} stale pid ${pid}; command did not match RoachNet runtime`)
    return
  }

  try {
    process.kill(pid, 'SIGTERM')
    if (!(await waitForPidExit(pid))) {
      process.kill(pid, 'SIGKILL')
    }
    await log(`stopped previous ${label} pid=${pid}`)
  } catch (error) {
    await log(`failed to stop previous ${label} pid=${pid}: ${error.message}`)
  }
}

function cleanupRuntimeStateFiles() {
  rmSync(statePath, { force: true })
  rmSync(processInfoPath, { force: true })
  if (process.env.ROACHNET_SERVER_INFO_FILE) {
    rmSync(process.env.ROACHNET_SERVER_INFO_FILE, { force: true })
  }
}

async function stopExistingRuntime() {
  try {
    const state = JSON.parse(readFileSync(statePath, 'utf8'))
    await terminateStatePid(Number(state.pid), ['run-roachnet-native-api.mjs'], 'native api')
    await terminateStatePid(Number(state.companionPid), ['roachnet-companion-server.mjs'], 'companion')
  } catch {}

  cleanupRuntimeStateFiles()
}

function sendJson(response, statusCode, value) {
  const payload = JSON.stringify(value)
  response.writeHead(statusCode, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(payload),
  })
  response.end(payload)
}

function updateStatus(stage, progress, message) {
  return {
    stage,
    progress,
    message,
    timestamp: new Date().toISOString(),
  }
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let bytes = 0
    let settled = false

    const fail = (error, destroy = false) => {
      if (settled) return
      settled = true
      reject(error)
      if (destroy) {
        request.destroy()
      } else {
        request.resume()
      }
    }

    const contentLength = Number(request.headers['content-length'] || 0)
    if (contentLength > NATIVE_API_MAX_REQUEST_BODY_BYTES) {
      fail(
        new NativeApiRequestError(
          `Request body is larger than ${NATIVE_API_MAX_REQUEST_BODY_BYTES} bytes.`,
          413
        )
      )
      return
    }

    request.on('data', (chunk) => {
      if (settled) return
      bytes += chunk.byteLength
      if (bytes > NATIVE_API_MAX_REQUEST_BODY_BYTES) {
        fail(
          new NativeApiRequestError(
            `Request body is larger than ${NATIVE_API_MAX_REQUEST_BODY_BYTES} bytes.`,
            413
          ),
          true
        )
        return
      }
      chunks.push(chunk)
    })
    request.on('end', () => {
      if (settled) return
      settled = true
      resolve(Buffer.concat(chunks).toString('utf8').trim())
    })
    request.on('error', (error) => {
      if (!settled) {
        settled = true
        reject(error)
      }
    })
  })
}

async function readRequestJson(request) {
  const raw = await readRequestBody(request)
  if (!raw) {
    return {}
  }
  // A page elsewhere can post text/plain or form bodies to loopback without a
  // preflight; it cannot send a JSON content type without one, and this API
  // answers no preflight.
  if (!declaresJsonBody(request.headers)) {
    throw new NativeApiRequestError('Request body must be sent as application/json.', 415)
  }

  try {
    return JSON.parse(raw)
  } catch {
    throw new NativeApiRequestError('Request body must be valid JSON.', 400)
  }
}

function parseDownloadUrl(rawUrl) {
  try {
    const parsed = new URL(String(rawUrl || '').trim())
    if (!['http:', 'https:'].includes(parsed.protocol)) {
      return null
    }
    return parsed.toString()
  } catch {
    return null
  }
}

// A download descriptor is a .json file under the Apps downloads base
// (ROACHNET_APPS_DOWNLOADS_BASE_URL). Any other URL, .json or not, downloads as
// the file it names, so no other host can point a download somewhere else.
function isAppsDownloadDescriptorUrl(rawUrl) {
  try {
    const parsed = new URL(String(rawUrl || '').trim())
    const base = new URL(appsDownloadsBaseUrl)
    const prefix = `${base.pathname.replace(/\/+$/, '')}/`
    return (
      ['http:', 'https:'].includes(parsed.protocol) &&
      parsed.pathname.endsWith('.json') &&
      parsed.origin === base.origin &&
      parsed.pathname.startsWith(prefix)
    )
  } catch {
    return false
  }
}

function pickDescriptorSource(descriptor) {
  const sources = Array.isArray(descriptor?.sources) ? descriptor.sources : []
  for (const source of sources) {
    const status = String(source?.status || '')
    if (source?.type === 'internet-archive-parts' || /(pending|required|blocked|failed)/i.test(status)) {
      continue
    }
    const candidate = parseDownloadUrl(source?.url)
    if (candidate) {
      return candidate
    }
  }
  return parseDownloadUrl(descriptor?.url || descriptor?.downloadUrl || descriptor?.archiveUrl)
}

function descriptorPartsAreUsable(descriptor) {
  const sources = Array.isArray(descriptor?.sources) ? descriptor.sources : []
  return sources.some((source) => {
    if (source?.type !== 'internet-archive-parts') return false
    const status = String(source?.status || '')
    return status && !/(pending|required|blocked|failed)/i.test(status)
  })
}

function descriptorParts(descriptor) {
  if (!descriptorPartsAreUsable(descriptor)) {
    return []
  }
  const parts = Array.isArray(descriptor?.parts) ? descriptor.parts : []
  const normalized = []
  for (const part of parts) {
    const url = parseDownloadUrl(part?.url)
    const bytes = Number(part?.bytes)
    const offset = Number(part?.offset)
    const sha256 = String(part?.sha256 || '').trim().toLowerCase()
    if (!url || !Number.isSafeInteger(bytes) || bytes <= 0) {
      return []
    }
    normalized.push({
      index: Number.isSafeInteger(Number(part?.index)) ? Number(part.index) : normalized.length,
      url,
      bytes,
      encodedBytes: Number.isSafeInteger(Number(part?.encodedBytes)) ? Number(part.encodedBytes) : null,
      offset: Number.isSafeInteger(offset) && offset >= 0 ? offset : null,
      sha256: /^[a-f0-9]{64}$/.test(sha256) ? sha256 : null,
      encoding: part?.encoding || null,
      header: typeof part?.header === 'string' ? part.header : null,
    })
  }
  return normalized.sort((a, b) => a.index - b.index)
}

async function resolveDownloadDescriptor(rawUrl) {
  const descriptorUrl = parseDownloadUrl(rawUrl)
  if (!descriptorUrl || !isAppsDownloadDescriptorUrl(descriptorUrl)) {
    return { url: descriptorUrl, descriptorUrl: null, sha256: null, parts: [] }
  }

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 30_000)
  try {
    const response = await fetch(descriptorUrl, {
      signal: controller.signal,
      headers: {
        accept: 'application/json',
        'user-agent': `RoachNet/${packageJson.version} descriptor-resolver`,
      },
    })
    if (!response.ok) {
      throw new Error(`HTTP ${response.status} while resolving ${descriptorUrl}`)
    }
    const descriptor = await response.json()
    const resolvedUrl = pickDescriptorSource(descriptor)
    if (!resolvedUrl) {
      const parts = descriptorParts(descriptor)
      if (parts.length === 0) {
        throw new Error(`Download descriptor has no usable HTTP source: ${descriptorUrl}`)
      }
    }
    const sha256 = String(descriptor.sha256 || '').trim().toLowerCase()
    const parts = descriptorParts(descriptor)
    return {
      url: parts.length > 0 ? descriptorUrl : resolvedUrl,
      descriptorUrl,
      sha256: /^[a-f0-9]{64}$/.test(sha256) ? sha256 : null,
      filename: descriptor.filename || null,
      bytes: Number.isSafeInteger(Number(descriptor.bytes)) ? Number(descriptor.bytes) : null,
      parts,
    }
  } finally {
    clearTimeout(timeout)
  }
}

function sendError(response, error, fallbackStatusCode = 500) {
  const statusCode = Number(error?.statusCode || fallbackStatusCode)
  // Only an Error's message goes back; anything else thrown stays in the log.
  sendJson(response, statusCode, { error: error instanceof Error ? error.message : 'The RoachNet runtime hit an unexpected error.' })
}

function abortErrorMessage(error, label) {
  if (error?.name === 'AbortError') {
    return `${label} timed out after ${NATIVE_API_DOWNLOAD_TIMEOUT_MS}ms.`
  }

  const message = error?.message || String(error)
  return `${label} failed: ${message}`
}

function closeFileStream(file) {
  if (!file || file.closed || file.destroyed) {
    return
  }

  file.destroy()
}

function normalizeVersion(value) {
  return String(value || '').trim().replace(/^v/i, '')
}

function parseVersionParts(value) {
  return normalizeVersion(value)
    .split(/[.+-]/)
    .map((part) => Number.parseInt(part, 10))
    .filter((part) => Number.isFinite(part))
}

function compareVersions(left, right) {
  const leftParts = parseVersionParts(left)
  const rightParts = parseVersionParts(right)
  const length = Math.max(leftParts.length, rightParts.length)

  for (let index = 0; index < length; index += 1) {
    const leftPart = leftParts[index] || 0
    const rightPart = rightParts[index] || 0
    if (leftPart > rightPart) return 1
    if (leftPart < rightPart) return -1
  }

  return 0
}

function readJsonFile(candidates, fallback) {
  for (const candidate of candidates) {
    const target = path.isAbsolute(candidate) ? candidate : path.join(repoRoot, candidate)
    try {
      if (existsSync(target)) {
        return JSON.parse(readFileSync(target, 'utf8'))
      }
    } catch {}
  }

  return fallback
}

async function fetchJson(url, options = {}) {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), options.timeout ?? 5_000)
  try {
    const response = await fetch(url, {
      ...options,
      signal: controller.signal,
      headers: {
        'content-type': 'application/json',
        'user-agent': `RoachNet/${packageJson.version} native-api`,
        ...(options.headers || {}),
      },
    })
    const text = await response.text()
    const data = text ? JSON.parse(text) : {}
    if (!response.ok) {
      throw new Error(data.error || data.message || `${response.status} ${response.statusText}`)
    }
    return data
  } finally {
    clearTimeout(timeout)
  }
}

function chooseReleaseForChannel(releases, channel) {
  if (!Array.isArray(releases)) return null
  if (channel === 'stable') {
    return releases.find((release) => !release.draft && !release.prerelease) || null
  }

  return (
    releases.find(
      (release) =>
        !release.draft &&
        (release.prerelease || String(release.tag_name || '').toLowerCase().includes(channel))
    ) ||
    releases.find((release) => !release.draft) ||
    null
  )
}

function selectInstallerAsset(release) {
  const assets = Array.isArray(release?.assets) ? release.assets : []
  return (
    assets.find((asset) => /RoachNet-Setup-macOS\.dmg$/i.test(asset.name || '')) ||
    assets.find((asset) => /RoachNet.*mac.*\.(dmg|zip)$/i.test(asset.name || '')) ||
    null
  )
}

async function resolveLatestRelease({ force = false } = {}) {
  if (!force && latestReleaseCache && Date.now() - latestReleaseCache.cachedAt < 10 * 60 * 1000) {
    return latestReleaseCache.release
  }

  const channel = process.env.ROACHNET_RELEASE_CHANNEL?.trim() || 'stable'
  const releases = await fetchJson(githubReleasesApiUrl, {
    headers: { accept: 'application/vnd.github+json' },
    timeout: 12_000,
  })
  const release = chooseReleaseForChannel(releases, channel)
  if (!release) {
    throw new Error(`No ${channel} RoachNet release was found.`)
  }

  const asset = selectInstallerAsset(release)
  const resolved = {
    currentVersion: packageJson.version,
    latestVersion: normalizeVersion(release.tag_name || release.name || packageJson.version),
    name: release.name || release.tag_name || 'RoachNet release',
    pageUrl: release.html_url || githubReleasesUrl,
    assetName: asset?.name || null,
    assetUrl: asset?.browser_download_url || release.html_url || githubReleasesUrl,
  }
  latestReleaseCache = { cachedAt: Date.now(), release: resolved }
  return resolved
}

async function latestVersionResponse(force = false) {
  try {
    const release = await resolveLatestRelease({ force })
    const updateAvailable = compareVersions(release.latestVersion, packageJson.version) > 0
    return {
      success: true,
      updateAvailable,
      currentVersion: packageJson.version,
      latestVersion: release.latestVersion,
      message: updateAvailable
        ? `RoachNet ${release.latestVersion} is available.`
        : 'RoachNet is current.',
      releaseUrl: release.pageUrl,
      assetUrl: release.assetUrl,
    }
  } catch (error) {
    return {
      success: false,
      updateAvailable: false,
      currentVersion: packageJson.version,
      latestVersion: packageJson.version,
      message: `Update check failed: ${error.message}`,
    }
  }
}

async function isReachable(url) {
  return runtimeReachabilityCache.get(url)
}

function findExecutable(candidates) {
  return candidates.find((candidate) => candidate && existsSync(candidate)) || null
}

async function ensureOllama() {
  const versionUrl = new URL('/api/version', ollamaBaseUrl).toString()
  if (await isReachable(versionUrl)) {
    return true
  }

  const localBin = process.env.ROACHNET_LOCAL_BIN_PATH || path.join(repoRoot, 'bin')
  const ollama = findExecutable([
    path.join(localBin, 'ollama'),
    '/opt/homebrew/bin/ollama',
    '/usr/local/bin/ollama',
  ])

  if (!ollama || ollamaProcess) {
    return false
  }

  const parsed = new URL(ollamaBaseUrl)
  ollamaProcess = spawn(ollama, ['serve'], {
    detached: true,
    stdio: 'ignore',
    env: {
      ...process.env,
      OLLAMA_HOST: `${parsed.hostname}:${parsed.port || '11434'}`,
      OLLAMA_MODELS: process.env.OLLAMA_MODELS || path.join(storageRoot, 'models', 'ollama'),
    },
  })
  ollamaProcess.unref()
  runtimeReachabilityCache.invalidate(versionUrl)
  installedModelsCache.invalidate(ollamaBaseUrl)
  await log(`started ollama pid=${ollamaProcess.pid}`)
  return false
}

async function providerStatus(provider, baseUrl) {
  const endpoint = provider === 'ollama' ? '/api/version' : '/health'
  const available = await isReachable(new URL(endpoint, baseUrl).toString())
  return {
    provider,
    available,
    source: available ? 'native-api' : 'configured',
    baseUrl,
    error: available ? null : `${provider} is not reachable yet.`,
  }
}

function safeServiceUrl(rawValue) {
  const raw = compactString(rawValue, '', 512)
  if (!raw) return ''
  try {
    const parsed = new URL(raw)
    parsed.username = ''
    parsed.password = ''
    parsed.search = ''
    parsed.hash = ''
    return parsed.toString().replace(/\/$/, '')
  } catch {
    return '[redacted-invalid-endpoint]'
  }
}

function serviceHealthStatusValue(available, configured = true) {
  if (!configured) return 'disabled'
  return available ? 'ok' : 'down'
}

function rollupServiceHealth(services = []) {
  const active = services.filter((service) => service.status !== 'disabled')
  if (!active.length) return 'disabled'
  if (active.some((service) => service.status === 'down')) return 'down'
  if (active.some((service) => service.status === 'degraded')) return 'degraded'
  return 'ok'
}

function roachClawServiceHealthState({
  ollama,
  openclaw,
  models = [],
  agent,
  services,
  uploadLimits,
  memoryProvider,
  embeddingLanes,
  scopedToolBridge,
} = {}) {
  const modelRecords = Array.isArray(models) ? models : []
  const serviceRecords = Array.isArray(services) ? services : serviceCatalog
  const uploadPolicy = uploadLimits || roachClawUploadLimitsState()
  const memoryState = memoryProvider || roachClawMemoryProviderState()
  const embeddingState = embeddingLanes || roachClawEmbeddingLanesState()
  const toolBridge = scopedToolBridge || roachClawScopedToolBridgeState()
  const memoryProviders = Array.isArray(memoryState.providers) ? memoryState.providers : []
  const enabledMemoryProviders = memoryProviders.filter((provider) => provider.enabled)
  const embeddingActive = Number(embeddingState.stats?.activeLaneCount || 0)
  const embeddingHealthy = Number(embeddingState.stats?.healthyLaneCount || 0)
  const updateIsError = ['error', 'failed'].includes(String(systemUpdateStatus.stage || systemUpdateStatus.status || '').toLowerCase())
  const serviceCatalogReady = serviceRecords.length > 0

  const servicesReport = [
    {
      name: 'ollama',
      label: 'Ollama local model runner',
      status: serviceHealthStatusValue(Boolean(ollama?.available), true),
      detail: ollama?.available
        ? 'Local model runner is reachable.'
        : 'Local model runner is not reachable yet; RoachClaw can still show local state.',
      meta: {
        provider: 'ollama',
        endpoint: safeServiceUrl(ollama?.baseUrl || ollamaBaseUrl),
        modelCount: modelRecords.length,
      },
    },
    {
      name: 'openclaw-compatibility',
      label: 'OpenClaw compatibility lane',
      status: openclaw?.available ? 'ok' : 'disabled',
      detail: openclaw?.available
        ? 'Compatibility endpoint is reachable.'
        : 'Compatibility lane is optional; native RoachClaw does not depend on it.',
      meta: {
        provider: 'openclaw',
        endpoint: safeServiceUrl(openclaw?.baseUrl || openClawBaseUrl),
      },
    },
    {
      name: 'roachclaw-native-agent',
      label: 'RoachClaw native agent',
      status: 'ok',
      detail: 'Native agent lane is available without Python, Flask, Electron, or WebUI.',
      meta: {
        runtime: agent?.runtime || 'native-api',
        configuredModel: agent?.configuredModel || defaultModel,
        resolvedModel: agent?.resolvedModel || null,
      },
    },
    {
      name: 'roachbrain-memory',
      label: 'RoachBrain memory provider',
      status: enabledMemoryProviders.length ? 'ok' : 'degraded',
      detail: enabledMemoryProviders.length
        ? 'At least one memory provider is enabled; RoachBrain native memory is the default.'
        : 'No enabled memory provider is visible.',
      meta: {
        providerCount: memoryProviders.length,
        enabledCount: enabledMemoryProviders.length,
      },
    },
    {
      name: 'embedding-lanes',
      label: 'Embedding lanes',
      status: embeddingState.health?.healthy ? 'ok' : 'degraded',
      detail: embeddingState.health?.healthy
        ? 'At least one embedding lane is healthy.'
        : 'Embedding lanes need attention before promotion.',
      meta: {
        laneCount: embeddingState.stats?.laneCount || 0,
        activeLaneCount: embeddingActive,
        healthyLaneCount: embeddingHealthy,
      },
    },
    {
      name: 'intake-policy',
      label: 'Intake policy',
      status: 'ok',
      detail: 'Upload, speech, media, calendar, and installer limits are enforced before large work can freeze the app.',
      meta: {
        policy: uploadPolicy.policy,
        limitCount: Array.isArray(uploadPolicy.limits) ? uploadPolicy.limits.length : 0,
      },
    },
    {
      name: 'scoped-tool-bridge',
      label: 'Scoped tool bridge',
      status: toolBridge.localOnly && toolBridge.approvalRequired ? 'ok' : 'degraded',
      detail: 'Tool access stays loopback-only with explicit approval and scoped route metadata.',
      meta: {
        scopeCount: Array.isArray(toolBridge.scopes) ? toolBridge.scopes.length : 0,
        endpointCount: Array.isArray(toolBridge.endpoints) ? toolBridge.endpoints.length : 0,
      },
    },
    {
      name: 'service-catalog',
      label: 'Service catalog',
      status: serviceCatalogReady ? 'ok' : 'degraded',
      detail: serviceCatalogReady
        ? 'Native service catalog is present for runtime controls.'
        : 'Native service catalog is empty.',
      meta: {
        serviceCount: serviceRecords.length,
        installedCount: serviceRecords.filter((service) => service.installed).length,
      },
    },
    {
      name: 'updates',
      label: 'Update lane',
      status: updateIsError ? 'degraded' : 'ok',
      detail: systemUpdateStatus.message || 'No update in progress.',
      meta: {
        stage: systemUpdateStatus.stage || systemUpdateStatus.status || 'idle',
      },
    },
  ]

  return {
    schema: 'org.roachnet.roachclaw.service-health.v1',
    source: 'github-upstream-service-health-native-rewrite',
    upstreamModule: 'src/service_health.py',
    route: '/api/roachclaw/diagnostics/services',
    overall: rollupServiceHealth(servicesReport),
    services: servicesReport,
    summaryItems: servicesReport.map((service) => `${service.label}: ${service.status}`),
    timestamp: new Date().toISOString(),
    budgets: {
      probeTimeoutMs: ROACHNET_SERVICE_HEALTH_PROBE_TIMEOUT_MS,
      networkProbes: 'bounded-non-intrusive-loopback-only',
      secretPolicy: 'redacted-endpoints-no-raw-exceptions',
    },
    defaultPosture: 'local-health-report-no-test-push-no-network-search',
  }
}

function systemInfo() {
  const cpus = os.cpus()
  const brand = cpus[0]?.model || 'Apple Silicon'
  const totalMemory = os.totalmem()
  const isAppleSilicon = process.platform === 'darwin' && process.arch === 'arm64'
  const memoryGB = totalMemory / 1024 / 1024 / 1024
  const memoryTier = memoryGB >= 32 ? 'creator' : memoryGB >= 16 ? 'balanced' : 'compact'
  const recommendedModelClass = memoryGB >= 32 ? '14b' : memoryGB >= 16 ? '7b' : '1.5b'

  return {
    cpu: {
      manufacturer: isAppleSilicon ? 'Apple' : null,
      brand,
      physicalCores: Math.max(1, Math.round(cpus.length / 2)),
      cores: cpus.length,
    },
    mem: {
      total: totalMemory,
      available: os.freemem(),
      swapused: null,
    },
    os: {
      hostname: os.hostname(),
      arch: process.arch,
      distro: `${os.type()} ${os.release()}`,
    },
    hardwareProfile: {
      platformLabel: isAppleSilicon ? 'Apple Silicon Mac' : `${process.platform} ${process.arch}`,
      chipFamily: isAppleSilicon ? 'apple_silicon' : process.arch,
      isAppleSilicon,
      memoryTier,
      recommendedRuntime: 'native_local',
      recommendedModelClass,
      notes: ['Native API bridge is running without the Electron/WebUI admin runtime.'],
      warnings: isAppleSilicon ? [] : ['This release target is Apple Silicon macOS.'],
    },
  }
}

async function installedModels() {
  await ensureOllama()
  try {
    return await installedModelsCache.get(ollamaBaseUrl)
  } catch {
    return []
  }
}

async function roachClawStatus() {
  await ensureOllama()
  const [ollama, openclaw, models] = await Promise.all([
    providerStatus('ollama', ollamaBaseUrl),
    providerStatus('openclaw', openClawBaseUrl),
    installedModels(),
  ])
  const modelNames = models.map((model) => model.name)
  const workspacePath = process.env.OPENCLAW_WORKSPACE_PATH || path.join(storageRoot, 'RoachClaw')
  const resolvedDefaultModel = modelNames.includes(defaultModel) ? defaultModel : (modelNames[0] || defaultModel)
  const agent = roachClawNativeAgentStatus({
    storageRoot,
    defaultModel,
    resolvedDefaultModel,
  })

  return {
    label: 'RoachClaw Native',
    ollama,
    openclaw,
    agent,
    operations: roachClawOperationsState({ ollama, openclaw, models, modelNames, agent }),
    cliStatus: {
      openclawAvailable: openclaw.available,
      clawhubAvailable: false,
      workspacePath,
      runner: 'native-api',
    },
    workspacePath,
    defaultModel,
    resolvedDefaultModel,
    preferredMode: 'local',
    ready: ollama.available,
    installedModels: modelNames,
    modelRecords: models,
    preferredModels: ['qwen2.5-coder:1.5b', 'qwen2.5-coder:7b', 'qwen2.5-coder:14b'],
    configFilePath: null,
    portableProfile: null,
    playbook: roachClawPlaybook({ ollama, openclaw, modelNames }),
  }
}

function roachClawShellSurfaces({
  tasks,
  calendar,
  reports,
  memories,
  skills,
  editorDrafts,
  searchCache,
  gallery,
  webhooks,
  agentRuns,
  contextCompactions,
  toolIndex,
  events,
  mail,
  presets,
  backups,
} = {}) {
  const taskRecords = Array.isArray(tasks?.tasks) ? tasks.tasks : []
  const calendarRecords = Array.isArray(calendar?.events) ? calendar.events : []
  const reportRecords = Array.isArray(reports?.reports) ? reports.reports : []
  const memoryRecords = Array.isArray(memories?.memories) ? memories.memories : []
  const skillRecords = Array.isArray(skills?.skills) ? skills.skills : []
  const draftRecords = Array.isArray(editorDrafts?.drafts) ? editorDrafts.drafts : []
  const searchRecords = Array.isArray(searchCache?.entries) ? searchCache.entries : []
  const galleryRecords = Array.isArray(gallery?.assets) ? gallery.assets : []
  const webhookRecords = Array.isArray(webhooks?.webhooks) ? webhooks.webhooks : []
  const runRecords = Array.isArray(agentRuns?.runs) ? agentRuns.runs : []
  const compactionRecords = Array.isArray(contextCompactions?.compactions) ? contextCompactions.compactions : []
  const toolRecords = Array.isArray(toolIndex?.tools) ? toolIndex.tools : []
  const eventRecords = Array.isArray(events?.events) ? events.events : []
  const mailDrafts = Array.isArray(mail?.drafts) ? mail.drafts : []
  const presetRecords = Array.isArray(presets?.templates) ? presets.templates : []
  const backupRecords = Array.isArray(backups?.snapshots) ? backups.snapshots : []

  const openTasks = taskRecords.filter((task) => !['done', 'cancelled', 'archived'].includes(String(task.status || '').toLowerCase())).length
  const activeRuns = runRecords.filter((run) => ['running', 'queued'].includes(String(run.status || '').toLowerCase())).length
  const stalledRuns = runRecords.filter((run) => ['stalled', 'blocked', 'error', 'failed'].includes(String(run.status || '').toLowerCase())).length
  const activeTools = toolRecords.filter((tool) => tool.enabled).length
  const armedHooks = webhookRecords.filter((hook) => hook.isActive).length
  const armedEvents = eventRecords.filter((event) => event.enabled).length
  const contextCount = memoryRecords.length + compactionRecords.length + searchRecords.length + draftRecords.length
  const commandCount = activeTools + skillRecords.length + presetRecords.length + armedHooks
  const vaultCount = galleryRecords.length + searchRecords.length + draftRecords.length + reportRecords.length
  const handoffCount = openTasks + calendarRecords.length + mailDrafts.length + armedEvents

  return {
    commandDeck: {
      status: commandCount ? 'indexed' : 'ready',
      count: commandCount,
      active: activeTools,
      priority: activeTools || commandCount ? 'fast-launch' : 'prime',
      route: 'roachnet://command',
      hotkey: 'Ctrl-Cmd-R',
      summaryItems: [
        `${activeTools} armed tools`,
        `${skillRecords.length} skills`,
        `${presetRecords.length} presets`,
        `${armedHooks} hooks`,
      ],
      detail: 'Raycast-style command surface backed by local tool cards, skills, presets, and scoped hooks.',
      actions: ['Search commands', 'Preview context', 'Run with approval', 'Pin useful actions'],
    },
    contextRail: {
      status: contextCount ? 'warm' : 'empty',
      count: contextCount,
      open: draftRecords.filter((draft) => !['archived', 'published', 'discarded'].includes(String(draft.status || '').toLowerCase())).length,
      priority: contextCount ? 'attached' : 'empty',
      route: 'roachnet://roachclaw/context',
      hotkey: 'Cmd-Shift-C',
      summaryItems: [
        `${memoryRecords.length} memories`,
        `${compactionRecords.length} compactions`,
        `${searchRecords.length} crumbs`,
        `${draftRecords.length} drafts`,
      ],
      detail: 'Cursor-style side rail for memories, compactions, search crumbs, and editable drafts.',
      actions: ['Show visible context', 'Compact thread', 'Attach vault crumb', 'Save working note'],
    },
    vaultNavigator: {
      status: vaultCount ? 'indexed' : 'empty',
      count: vaultCount,
      active: galleryRecords.length,
      priority: vaultCount ? 'browse' : 'feed',
      route: 'roachnet://vault',
      hotkey: 'Cmd-Shift-V',
      summaryItems: [
        `${galleryRecords.length} assets`,
        `${reportRecords.length} reports`,
        `${searchRecords.length} source crumbs`,
        `${draftRecords.length} drafts`,
      ],
      detail: 'Finder-like local navigator for vault assets, report outputs, source crumbs, and staged drafts.',
      actions: ['Browse vault', 'Preview asset', 'Reveal path', 'Drop files into shelf'],
    },
    agentMonitor: {
      status: activeRuns ? 'running' : (stalledRuns ? 'needs-review' : 'idle'),
      count: runRecords.length,
      active: activeRuns,
      stalled: stalledRuns,
      priority: stalledRuns ? 'review' : (activeRuns ? 'watch' : 'idle'),
      route: 'roachnet://roachclaw/runs',
      hotkey: 'Cmd-Shift-M',
      summaryItems: [
        `${activeRuns} running`,
        `${stalledRuns} stalled`,
        `${eventRecords.length} counters`,
        `${toolRecords.length} tools`,
      ],
      detail: 'Activity Monitor-style view of autonomous RoachClaw runs, replay crumbs, and local event pressure.',
      actions: ['Inspect run', 'Stop noisy work', 'Replay events', 'Collect evidence'],
    },
    orchestrationDashboard: {
      status: activeRuns || handoffCount ? 'coordinating' : 'ready',
      count: runRecords.length + reportRecords.length + backupRecords.length,
      active: activeRuns,
      open: handoffCount,
      priority: activeRuns || handoffCount ? 'coordinate' : 'ready',
      route: 'roachnet://roachclaw/orchestration',
      hotkey: 'Cmd-Shift-O',
      summaryItems: [
        `${runRecords.length} runs`,
        `${openTasks} open tasks`,
        `${calendarRecords.length} calendar`,
        `${backupRecords.length} snapshots`,
      ],
      detail: 'Monet-style dashboard for local agent roles, context budgets, handoffs, and outcome ledgers.',
      actions: ['Assign roles', 'Set context budgets', 'Track handoffs', 'Publish outcome'],
    },
  }
}

function roachClawOperationsState({ ollama, openclaw, models = [], modelNames = [], agent } = {}) {
  const now = new Date().toISOString()
  const jobs = downloadJobs.map((job) => ({
    id: job.jobId,
    kind: job.filetype,
    status: job.status || 'queued',
    progress: job.progress,
    target: job.filepath,
    updatedAt: job.updatedAt || null,
  }))
  const contacts = roachClawContactsState()
  const tasks = roachClawTaskState()
  const calendar = roachClawCalendarState()
  const reports = roachClawReportsState()
  const memories = roachClawMemoriesState()
  const skills = roachClawSkillsState()
  const editorDrafts = roachClawEditorDraftsState()
  const migrationDocumentTools = roachClawMigrationDocumentToolsState()
  const searchCache = roachClawSearchCacheState()
  const gallery = roachClawGalleryState()
  const webhooks = roachClawWebhooksState()
  const agentRuns = roachClawAgentRunsState()
  const contextCompactions = roachClawContextCompactionsState()
  const toolIndex = roachClawToolIndexState()
  const events = roachClawEventsState()
  const mail = roachClawMailState()
  const presets = roachClawPresetsState()
  const signatures = roachClawSignaturesState()
  const apiTokens = roachClawPublicApiTokensState()
  const cloudProviders = roachClawPublicCloudProviderKeysState()
  const backups = roachClawBackupsState()
  const userTime = roachClawUserTimeState()
  const cookbookServe = roachClawCookbookServeState()
  const readiness = roachClawReadinessState()
  const contextBudget = roachClawContextBudgetState()
  const scopedToolBridge = roachClawScopedToolBridgeState()
  const tlsOverrides = roachClawTlsOverridesState()
  const uploadLimits = roachClawUploadLimitsState()
  const memoryProvider = roachClawMemoryProviderState()
  const providerOAuth = roachClawProviderOAuthState()
  const embeddingLanes = roachClawEmbeddingLanesState()
  const toolPolicy = roachClawToolPolicyState()
  const serviceHealth = roachClawServiceHealthState({
    ollama,
    openclaw,
    models,
    agent,
    services: serviceCatalog,
    uploadLimits,
    memoryProvider,
    embeddingLanes,
    scopedToolBridge,
  })
  const shellSurfaces = roachClawShellSurfaces({
    tasks,
    calendar,
    reports,
    memories,
    skills,
    editorDrafts,
    searchCache,
    gallery,
    webhooks,
    agentRuns,
    contextCompactions,
    toolIndex,
    events,
    mail,
    presets,
    backups,
  })

  return {
    schema: 'org.roachnet.roachclaw.operations.v1',
    updatedAt: now,
    diagnostics: {
      status: ollama?.available ? 'ready' : 'needs-runtime',
      probes: [
        {
          id: 'ollama',
          label: 'Ollama',
          available: Boolean(ollama?.available),
          detail: ollama?.error || 'Local model runner probe.',
        },
        {
          id: 'openclaw',
          label: 'OpenClaw compatibility lane',
          available: Boolean(openclaw?.available),
          detail: openclaw?.error || 'Compatibility probe only; RoachClaw is native-first.',
        },
        {
          id: 'roachclaw-native-agent',
          label: 'RoachClaw native agent',
          available: true,
          detail: `${agent?.runtime || 'native agent'} is available without a WebUI bridge.`,
        },
      ],
      warnings: [
        ...(!ollama?.available ? ['Ollama is not reachable yet; local chat wakes up when the runner starts.'] : []),
        ...(modelNames.length === 0 ? ['No local model packs are installed yet.'] : []),
      ],
    },
    serviceHealth: {
      status: serviceHealth.overall,
      count: serviceHealth.services.length,
      active: serviceHealth.services.filter((service) => service.status === 'ok').length,
      route: 'roachnet://runtime/service-health',
      summaryItems: serviceHealth.summaryItems,
      detail: 'Native degraded-state report for the model runner, agent, memory, embeddings, intake policy, service catalog, tools, and updates.',
      actions: ['Run service health', 'Inspect degraded lanes', 'Copy safe report'],
      report: serviceHealth,
    },
    contacts: {
      status: 'local-first',
      storagePath: roachClawVaultPath('contacts.json'),
      recordCount: contacts.contacts.length,
      records: contacts.contacts.slice(0, 12),
      scopes: ['local-address-book', 'reply-recipient-context', 'account-owned-routing'],
      notes: ['Contacts are modeled as a local context lane; no hosted CRM is required.'],
    },
    hooks: {
      status: 'armed-local-only',
      storagePath: roachClawVaultPath('hooks.json'),
      endpoints: [
        {
          id: 'companion-install',
          method: 'POST',
          path: '/api/companion/install',
          scope: 'app-store-install',
        },
        {
          id: 'agent-run',
          method: 'POST',
          path: '/api/roachclaw/agent/run',
          scope: 'approval-gated-agent-run',
        },
      ],
      secretsPolicy: 'local-redacted',
    },
    jobs: {
      status: jobs.some((job) => ['queued', 'downloading'].includes(job.status)) ? 'running' : 'idle',
      update: systemUpdateStatus,
      downloads: jobs,
      scheduler: {
        status: 'local-queue',
        storagePath: roachClawVaultPath('jobs.json'),
        pending: jobs.filter((job) => ['queued', 'downloading'].includes(job.status)).length + tasks.tasks.filter((task) => !['done', 'cancelled', 'archived'].includes(String(task.status || '').toLowerCase())).length,
      },
    },
    notesTasks: {
      status: tasks.tasks.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('tasks.json'),
      count: tasks.tasks.length,
      open: tasks.tasks.filter((task) => !['done', 'cancelled', 'archived'].includes(String(task.status || '').toLowerCase())).length,
      records: tasks.tasks.slice(0, 12),
    },
    calendar: {
      status: calendar.events.length ? 'planned' : 'empty',
      storagePath: roachClawVaultPath('calendar.json'),
      count: calendar.events.length,
      records: calendar.events.slice(0, 12),
    },
    reports: {
      status: reports.reports.length ? 'tracking' : 'ready',
      root: roachClawVaultPath('reports'),
      formats: ['markdown', 'json', 'pdf-ready-html'],
      templates: [
        'research-brief',
        'model-compare',
        'diagnostics-report',
        'vault-source-map',
      ],
      count: reports.reports.length,
      records: reports.reports.slice(0, 12),
    },
    memories: {
      status: memories.memories.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('memories.json'),
      count: memories.memories.length,
      records: memories.memories.slice(0, 12),
    },
    skills: {
      status: skills.skills.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('skills.json'),
      count: skills.skills.length,
      records: skills.skills.slice(0, 12),
    },
    editorDrafts: {
      status: editorDrafts.drafts.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('editor-drafts.json'),
      count: editorDrafts.drafts.length,
      open: editorDrafts.drafts.filter((draft) => !['archived', 'published', 'discarded'].includes(String(draft.status || '').toLowerCase())).length,
      records: editorDrafts.drafts.slice(0, 12),
    },
    migrationDocumentTools,
    searchCache: {
      status: searchCache.entries.length ? 'warm' : 'empty',
      storagePath: roachClawVaultPath('search-cache.json'),
      count: searchCache.entries.length,
      records: searchCache.entries.slice(0, 12),
    },
    gallery: {
      status: gallery.assets.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('gallery.json'),
      count: gallery.assets.length,
      records: gallery.assets.slice(0, 12),
    },
    webhooks: {
      status: webhooks.webhooks.some((hook) => hook.isActive) ? 'armed' : 'empty',
      storagePath: roachClawVaultPath('webhooks.json'),
      count: webhooks.webhooks.length,
      active: webhooks.webhooks.filter((hook) => hook.isActive).length,
      records: webhooks.webhooks.slice(0, 12),
      secretsPolicy: 'sha256-digest-only-raw-secret-never-exported',
    },
    agentRuns: {
      status: agentRuns.runs.some((run) => ['running', 'queued'].includes(String(run.status || '').toLowerCase())) ? 'running' : (agentRuns.runs.length ? 'tracked' : 'empty'),
      storagePath: roachClawVaultPath('agent-runs.json'),
      count: agentRuns.runs.length,
      active: agentRuns.runs.filter((run) => ['running', 'queued'].includes(String(run.status || '').toLowerCase())).length,
      records: agentRuns.runs.slice(0, 12),
      retention: 'local-replay-buffer-metadata',
    },
    contextCompactions: {
      status: contextCompactions.compactions.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('context-compactions.json'),
      count: contextCompactions.compactions.length,
      records: contextCompactions.compactions.slice(0, 12),
      retention: 'summary-plus-token-budget',
    },
    toolIndex: {
      status: toolIndex.tools.length ? 'indexed' : 'empty',
      storagePath: roachClawVaultPath('tool-index.json'),
      count: toolIndex.tools.length,
      active: toolIndex.tools.filter((tool) => tool.enabled).length,
      records: toolIndex.tools.slice(0, 12),
      selectionPolicy: 'local-ranked-tool-cards',
    },
    events: {
      status: events.events.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('events.json'),
      count: events.events.length,
      active: events.events.filter((event) => event.enabled).length,
      records: events.events.slice(0, 12),
      delivery: 'local-counter-gated-actions',
    },
    commandDeck: shellSurfaces.commandDeck,
    contextRail: shellSurfaces.contextRail,
    vaultNavigator: shellSurfaces.vaultNavigator,
    agentMonitor: shellSurfaces.agentMonitor,
    orchestrationDashboard: shellSurfaces.orchestrationDashboard,
    mail: {
      status: mail.messages.length || mail.drafts.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('mail.json'),
      count: mail.messages.length + mail.drafts.length,
      messages: mail.messages.length,
      drafts: mail.drafts.length,
      records: [...mail.drafts.slice(0, 6), ...mail.messages.slice(0, 6)],
    },
    presets: {
      status: presets.templates.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('presets.json'),
      count: presets.templates.length,
      templates: presets.templates.slice(0, 12),
    },
    signatures: {
      status: signatures.signatures.length ? 'tracking' : 'empty',
      storagePath: roachClawVaultPath('signatures.json'),
      count: signatures.signatures.length,
      records: signatures.signatures.slice(0, 12),
    },
    apiTokens: {
      status: apiTokens.tokens.some((token) => token.isActive) ? 'armed' : 'empty',
      storagePath: roachClawVaultPath('api-tokens.json'),
      count: apiTokens.tokens.length,
      active: apiTokens.tokens.filter((token) => token.isActive).length,
      records: apiTokens.tokens.slice(0, 12),
      secretsPolicy: 'sha256-hash-only-token-returned-on-create',
    },
    cloudProviders: {
      status: cloudProviders.active ? 'user-armed' : 'local-default',
      storagePath: roachClawVaultPath('cloud-provider-keys.json'),
      count: cloudProviders.count,
      active: cloudProviders.active,
      configured: cloudProviders.configured,
      records: cloudProviders.providers,
      secretsPolicy: cloudProviders.secretsPolicy,
      defaultPosture: 'local-first-roachclaw-with-optional-user-owned-cloud-keys',
    },
    workspaceBrowser: {
      status: 'ready',
      root: roachClawWorkspaceBrowseRoot(),
      count: 0,
      route: 'roachnet://dev/workspace',
      hotkey: 'Cmd-Shift-W',
      summaryItems: ['directories only', 'dotfiles hidden', 'symlinks not followed'],
      detail: 'Native workspace picker for Dev and RoachClaw context. It lists folders without exposing the rest of the filesystem to a WebUI bridge.',
      actions: ['Browse workspace', 'Attach folder', 'Pin project', 'Send to RoachClaw'],
    },
    userTime: {
      status: userTime.configured ? 'configured' : 'system-default',
      storagePath: roachClawVaultPath('user-time.json'),
      count: userTime.configured ? 1 : 0,
      route: 'roachnet://settings/time',
      summaryItems: [userTime.timeZoneName, userTime.utcOffset, userTime.localDateTime].filter(Boolean),
      detail: 'Local time context for schedulers and RoachClaw prompts, so relative dates stop guessing at your calendar.',
      actions: ['Set timezone', 'Refresh clock context', 'Attach to prompt'],
    },
    cookbookServeLifecycle: {
      status: cookbookServe.active ? 'scheduled' : 'idle',
      storagePath: roachClawVaultPath('cookbook-serve-schedules.json'),
      count: cookbookServe.schedules.length,
      active: cookbookServe.active,
      queued: cookbookServe.pending,
      route: 'roachnet://roachclaw/cookbook',
      summaryItems: [
        `${cookbookServe.schedules.length} schedules`,
        `${cookbookServe.active} active`,
        `${cookbookServe.pending} waiting`,
      ],
      detail: 'Native model-serve scheduling and stop windows rewritten as RoachNet local state.',
      actions: ['Schedule model', 'Mirror calendar', 'Stop expired serves', 'Inspect progress'],
    },
    readiness: {
      status: readiness.ready ? 'ready' : 'needs-attention',
      storagePath: readiness.checks.storageRoot?.path || storageRoot,
      count: Object.keys(readiness.checks).length,
      active: Object.values(readiness.checks).filter((check) => check.ok).length,
      route: 'roachnet://runtime/readiness',
      summaryItems: [
        readiness.ready ? 'all checks passed' : 'checks need review',
        readiness.localFirst ? 'local-first' : 'remote storage warning',
        `${Object.keys(readiness.checks).length} checks`,
      ],
      detail: 'Native readiness probe for storage, vault, runtime state, and local-first posture before RoachClaw takes real work.',
      actions: ['Run readiness', 'Open storage', 'Inspect warnings'],
    },
    contextBudget: {
      status: contextBudget.explicit ? 'user-set' : 'adaptive',
      storagePath: roachClawVaultPath('context-budget.json'),
      count: contextBudget.effectiveBudget,
      active: contextBudget.modelContextLength,
      route: 'roachnet://roachclaw/context-budget',
      summaryItems: [
        `${contextBudget.effectiveBudget} tokens`,
        contextBudget.explicit ? 'explicit' : 'adaptive',
        `${contextBudget.headroomPercent}% headroom`,
      ],
      detail: 'Adaptive input-token budget so long-context local models are not silently capped at tiny defaults.',
      actions: ['Tune budget', 'Probe model window', 'Apply headroom'],
    },
    urlSafety: {
      status: 'armed',
      count: 2,
      route: 'roachnet://settings/url-safety',
      summaryItems: ['http/https only', 'metadata IPs blocked', 'private block optional'],
      detail: 'Checks user-supplied outbound URLs before RoachClaw or integrations fetch them.',
      actions: ['Check URL', 'Block metadata targets', 'Review provider endpoint'],
    },
    scopedToolBridge: {
      status: 'ready',
      storagePath: roachClawVaultPath('scoped-tool-bridge.json'),
      count: scopedToolBridge.scopes.length,
      active: scopedToolBridge.endpoints.length,
      route: 'roachnet://roachclaw/tools',
      summaryItems: scopedToolBridge.scopes.slice(0, 4),
      detail: 'Native scoped tool bridge for local actions, designed without shipping a Python plugin server.',
      actions: ['List scopes', 'Inspect endpoints', 'Require approval', 'Export manifest'],
    },
    tlsOverrides: {
      status: tlsOverrides.configured ? (tlsOverrides.valid ? 'configured' : 'invalid-path') : 'default-trust',
      storagePath: roachClawVaultPath('tls-overrides.json'),
      count: tlsOverrides.configured ? 1 : 0,
      active: tlsOverrides.valid ? 1 : 0,
      route: 'roachnet://settings/provider-security',
      summaryItems: [tlsOverrides.scope, tlsOverrides.bundleLabel].filter(Boolean),
      detail: 'Optional extra CA bundle metadata for user-owned provider routes. Verification stays on; there is no insecure off switch.',
      actions: ['Set CA bundle', 'Clear override', 'Inspect scope'],
    },
    uploadLimits: {
      status: 'enforced',
      count: uploadLimits.limits.length,
      route: 'roachnet://vault/imports',
      summaryItems: uploadLimits.summaryItems,
      detail: 'Native request, upload, and download byte caps stay explicit so oversized imports fail cleanly instead of freezing the app.',
      actions: ['Inspect limits', 'Retry smaller file', 'Open vault imports'],
    },
    memoryProvider: {
      status: memoryProvider.providers.some((provider) => provider.enabled) ? 'native-provider' : 'empty',
      storagePath: roachClawVaultPath('memory-provider.json'),
      count: memoryProvider.providers.length,
      active: memoryProvider.providers.filter((provider) => provider.enabled).length,
      route: 'roachnet://roachbrain/providers',
      summaryItems: memoryProvider.providers.map((provider) => provider.displayName).slice(0, 3),
      detail: 'Provider-neutral memory contract rewritten as RoachBrain local state; external memory systems stay opt-in.',
      actions: ['List providers', 'Recall memory', 'Write local memory', 'Audit tools'],
    },
    providerOAuth: {
      status: providerOAuth.flows.some((flow) => flow.needsUserAction) ? 'needs-user-action' : 'idle',
      storagePath: roachClawVaultPath('provider-oauth.json'),
      count: providerOAuth.flows.length,
      active: providerOAuth.flows.filter((flow) => flow.isActive).length,
      route: 'roachnet://settings/provider-oauth',
      summaryItems: providerOAuth.flows.map((flow) => flow.provider).slice(0, 4),
      detail: 'OAuth metadata for user-owned remote tools. Tokens are not exported, and local RoachClaw remains the default lane.',
      actions: ['Start user flow', 'Cancel pending flow', 'Review scopes'],
    },
    embeddingLanes: {
      status: embeddingLanes.health.status,
      storagePath: roachClawVaultPath('embedding-lanes.json'),
      count: embeddingLanes.lanes.length,
      active: embeddingLanes.lanes.filter((lane) => lane.enabled).length,
      route: 'roachnet://roachbrain/embedding-lanes',
      summaryItems: embeddingLanes.lanes.map((lane) => `${lane.label}: ${lane.dimension ? `${lane.dimension}d` : lane.health.status}`).slice(0, 4),
      detail: 'Separate local and custom embedding lanes with fingerprints, reset safety, health, and stats, kept as native RoachBrain state.',
      actions: ['Inspect lanes', 'Check fingerprints', 'Reset safely', 'Reindex local memory'],
    },
    toolPolicy: {
      status: toolPolicy.mode === 'guide_only' ? 'guide-only' : 'enforced',
      storagePath: roachClawVaultPath('tool-policy.json'),
      count: toolPolicy.knownToolCount,
      active: toolPolicy.disabledCount,
      route: 'roachnet://roachclaw/tool-policy',
      summaryItems: toolPolicy.display.summaryItems,
      detail: 'Per-turn tool policy metadata for guide-only detection, prompt hiding, disabled tools, and native display.',
      actions: ['Evaluate prompt', 'Hide disabled tools', 'Show enforcement reason', 'Review scopes'],
    },
    backups: {
      status: backups.snapshots.length ? 'tracking' : 'ready',
      storagePath: roachClawVaultPath('backups.json'),
      count: backups.snapshots.length,
      snapshots: backups.snapshots.slice(0, 12),
    },
    uploads: {
      status: 'vault-scoped',
      root: path.join(storageRoot, 'Vault'),
      maxRequestBytes: NATIVE_API_MAX_REQUEST_BODY_BYTES,
      ownership: 'local-user',
      isolation: 'sanitize-name-and-copy-into-vault',
    },
    preferences: {
      status: 'native-settings',
      storagePath: path.join(runtimeStateRoot, 'roachclaw-preferences.json'),
      scrubPolicy: 'export-redacts-local-secrets-and-machine-paths',
      appearance: ['system', 'dark', 'high-contrast'],
    },
    adminRecovery: {
      status: 'local-owner-required',
      actions: ['first-run-owner-claim', 'reset-local-agent-state', 'scrub-settings-export'],
      remoteAccess: false,
    },
    models: {
      count: models.length,
      installed: modelNames,
    },
  }
}

function roachClawPlaybook({ ollama, openclaw, modelNames = [] } = {}) {
  const hasLocalModels = modelNames.length > 0
  const activeModel = modelNames.includes(defaultModel) ? defaultModel : (modelNames[0] || defaultModel)
  const localReady = Boolean(ollama?.available)
  const agentReady = Boolean(openclaw?.available)
  const now = new Date().toISOString()
  const statusFor = (requiredModels = false, requiredAgent = false) => {
    if (requiredModels && !hasLocalModels) return 'needs-model'
    if (requiredAgent && !agentReady) return 'agent-warmup'
    return localReady ? 'ready' : 'runtime-warmup'
  }

  return {
    schema: 'org.roachnet.roachclaw.playbook.v1',
    source: 'roachnet-native',
    updatedAt: now,
    capabilities: [
      'roachclaw-cookbook',
      'roachclaw-quant-aware-fit',
      'roachclaw-deep-research',
      'roachclaw-model-compare',
      'roachbrain-memory-skills-audit',
      'vault-document-assist',
      'roachspeech-voice-lane',
      'roachmail-triage',
      'roachcalendar-planning',
      'roachtasks-reminders',
      'roachgallery-media-tools',
      'roachclaw-mcp-tools',
      'roachclaw-web-search',
      'roachclaw-secure-actions',
      'roachclaw-admin-recovery',
      'roachclaw-provider-diagnostics',
      'roachclaw-contacts-context',
      'roachclaw-webhooks',
      'roachclaw-visual-reports',
      'roachclaw-preferences',
      'roachclaw-background-jobs',
      'roachclaw-upload-safety',
      'roachclaw-agent-run-monitor',
      'roachclaw-context-rail',
      'roachclaw-tool-index',
      'roachclaw-event-counters',
      'roachclaw-command-deck',
      'roachclaw-contextual-side-panel',
      'roachclaw-vault-navigator',
      'roachclaw-agent-activity-monitor',
      'roachclaw-orchestration-dashboard',
      'roachclaw-session-board',
      'roachclaw-model-bench',
      'roachclaw-document-lab',
      'roachclaw-theme-studio',
      'roachclaw-assistant-crew',
      'roachclaw-session-history',
      'roachclaw-provider-routes',
      'roachclaw-backup-restore',
      'roachclaw-signatures',
      'roachclaw-local-api-keys',
      'roachclaw-user-cloud-provider-keys',
      'roachclaw-workspace-browser',
      'roachclaw-user-time-context',
      'roachclaw-cookbook-serve-lifecycle',
      'roachclaw-url-security',
      'roachclaw-scoped-tool-bridge',
      'roachclaw-tls-overrides',
      'roachclaw-upload-limits',
      'roachclaw-service-health',
      'roachbrain-memory-provider',
      'roachclaw-provider-oauth',
      'roachbrain-embedding-lanes',
      'roachclaw-tool-policy',
      'roachclaw-streaming-markdown',
      'roachclaw-migration-document-tools',
      'roachclaw-font-emoji-assets',
      'roachclaw-housekeeping',
    ],
    referenceSource: {
      repository: roachClawReferenceRepository,
      commit: roachClawReferenceCommit,
      latestSeenCommit: roachClawReferenceLatestCommit,
      posture: 'reference-only-native-rewrite',
      sourceKind: 'github-upstream',
    },
    featureGroups: roachClawNativeFeatureGroups({ hasLocalModels, localReady, agentReady }),
    referenceModules: roachClawReferenceModules(),
    referenceInventory: roachClawReferenceInventory(),
    coverage: roachClawParityCoverage({ hasLocalModels, localReady, agentReady }),
    lanes: [
      {
        id: 'session-board',
        title: 'Session Board',
        summary: 'Keep chats, detached runs, replay crumbs, and saved context in one native lane instead of scattered browser history.',
        status: 'native-state',
        icon: 'rectangle.stack.badge.person.crop',
        accent: 'cyan',
        localFirst: true,
        actions: ['Open sessions', 'Resume run', 'Attach context', 'Save transcript'],
      },
      {
        id: 'model-bench',
        title: 'Model Bench',
        summary: hasLocalModels
          ? `Stage ${activeModel}, compare rivals, and save the winner before trusting a model with real work.`
          : 'Install one model to unlock native fit checks, blind tests, and serve plans.',
        status: hasLocalModels ? 'native-ready' : 'needs-model',
        icon: 'slider.horizontal.below.rectangle',
        accent: 'magenta',
        localFirst: true,
        actions: ['Fit model', 'Run blind compare', 'Save winner', 'Open model packs'],
      },
      {
        id: 'cookbook',
        title: 'RoachClaw Cookbook',
        summary: hasLocalModels
          ? `Use ${activeModel} first, then check quantized and MoE packs against real Apple Silicon headroom.`
          : 'Scan the machine, unpack quantized model sizes, and stop guessing which brain fits this box.',
        status: statusFor(true, false),
        icon: 'cpu',
        accent: 'green',
        localFirst: true,
        actions: ['Scan hardware', 'Unpack quantized sizes', 'Recommend a model', 'Open model store'],
      },
      {
        id: 'workspace-browser',
        title: 'Workspace Browser',
        summary: 'Browse project folders for Dev and RoachClaw context without handing filesystem navigation to a Python WebUI.',
        status: 'native-state',
        icon: 'folder.badge.gearshape',
        accent: 'cyan',
        localFirst: true,
        actions: ['Browse folders', 'Attach project', 'Pin workspace', 'Send context'],
      },
      {
        id: 'deep-research',
        title: 'Deep Research',
        summary: 'Gather sources, read them, and turn the mess into a brief RoachNet can save.',
        status: statusFor(true, true),
        icon: 'doc.text.magnifyingglass',
        accent: 'cyan',
        localFirst: true,
        actions: ['Plan questions', 'Collect sources', 'Write a cited brief'],
      },
      {
        id: 'compare',
        title: 'Compare',
        summary: hasLocalModels && modelNames.length > 1
          ? `Blind-test ${modelNames.slice(0, 2).join(' vs ')} before marrying either answer.`
          : 'Stage two routes and compare answers before trusting the loudest model.',
        status: modelNames.length > 1 ? statusFor(true, false) : 'needs-second-model',
        icon: 'rectangle.split.2x1',
        accent: 'magenta',
        localFirst: true,
        actions: ['Run A/B prompt', 'Hide model labels', 'Save the winner'],
      },
      {
        id: 'memory-skills',
        title: 'RoachBrain Audit',
        summary: 'Save procedures that worked, compact context that matters, and keep useful habits close.',
        status: 'ready',
        icon: 'brain.head.profile',
        accent: 'bronze',
        localFirst: true,
        actions: ['Save memory', 'Audit skills', 'Compact context', 'Export context'],
      },
      {
        id: 'agent-monitor',
        title: 'Agent Monitor',
        summary: 'Track autonomous runs, replay crumbs, tool cards, and local event counters like Activity Monitor for RoachClaw.',
        status: 'native-ready',
        icon: 'bolt.badge.clock',
        accent: 'green',
        localFirst: true,
        actions: ['Open run history', 'Review tool index', 'Check event counters', 'Stop noisy work'],
      },
      {
        id: 'documents',
        title: 'Document Lab',
        summary: 'Draft, rewrite, summarize, and file the useful bits without turning every note into a cloud trip.',
        status: 'ready',
        icon: 'doc.richtext',
        accent: 'cyan',
        localFirst: true,
        actions: ['Summarize a doc', 'Rewrite a section', 'Save to vault'],
      },
      {
        id: 'migration-document-tools',
        title: 'Migration + Document Tools',
        summary: 'Turn Office files, active docs, saved chats, and recipe logs into local RoachNet context without dragging a web stack along.',
        status: 'native-state',
        icon: 'doc.badge.gearshape',
        accent: 'cyan',
        localFirst: true,
        actions: ['Import Office doc', 'Preview migration', 'Validate target', 'Classify output'],
      },
      {
        id: 'theme-studio',
        title: 'Theme Studio',
        summary: 'Tune the shell palette, density, motion, and readable chaos without editing a config file like it owes you money.',
        status: 'native-ready',
        icon: 'paintpalette',
        accent: 'bronze',
        localFirst: true,
        actions: ['Switch density', 'Tune motion', 'Preview theme', 'Export settings'],
      },
      {
        id: 'voice',
        title: 'Voice',
        summary: 'Dictate prompts, listen to replies, and keep RoachClaw usable when your hands are busy.',
        status: 'ready',
        icon: 'waveform',
        accent: 'magenta',
        localFirst: true,
        actions: ['Start dictation', 'Read latest reply', 'Choose voice pack'],
      },
      {
        id: 'inbox-calendar',
        title: 'Inbox + Calendar',
        summary: 'Stage local-first triage, reminders, and calendar moves without making email the boss of the day.',
        status: 'planned-native',
        icon: 'tray.and.arrow.down',
        accent: 'cyan',
        localFirst: true,
        actions: ['Triage inbox', 'Draft reply', 'Plan calendar'],
      },
      {
        id: 'gallery-media',
        title: 'Gallery + Media Tools',
        summary: 'Collect images, documents, and generated assets into a vault-aware media lane instead of another loose folder.',
        status: 'planned-native',
        icon: 'photo.on.rectangle',
        accent: 'green',
        localFirst: true,
        actions: ['Import media', 'Tag assets', 'Export bundle'],
      },
      {
        id: 'diagnostics-control',
        title: 'Diagnostics + Control',
        summary: 'Probe providers, scrub settings, check degraded services, and keep admin-grade controls behind local approval.',
        status: 'native-ready',
        icon: 'stethoscope',
        accent: 'bronze',
        localFirst: true,
        actions: ['Run diagnostics', 'Scrub settings', 'Review admin actions'],
      },
      {
        id: 'service-health',
        title: 'Service Health',
        summary: 'Roll up runtime, model runner, memory, embeddings, intake, updates, and service catalog health without poking the outside world.',
        status: 'native-state',
        icon: 'waveform.path.ecg.rectangle',
        accent: 'green',
        localFirst: true,
        actions: ['Run service health', 'Inspect degraded lanes', 'Copy safe report'],
      },
      {
        id: 'integrations-hooks',
        title: 'Contacts + Hooks',
        summary: 'Keep contacts, provider routes, webhooks, and external handoffs scoped so integrations do not become custody.',
        status: 'planned-native',
        icon: 'person.2.wave.2',
        accent: 'cyan',
        localFirst: true,
        actions: ['Review contacts', 'Inspect webhooks', 'Check provider routes'],
      },
      {
        id: 'reports-workbench',
        title: 'Reports + Background Jobs',
        summary: 'Track visual reports, scheduled runs, session deliveries, and background work as explicit jobs instead of hidden noise.',
        status: 'planned-native',
        icon: 'chart.bar.doc.horizontal',
        accent: 'magenta',
        localFirst: true,
        actions: ['Open job queue', 'Render report', 'Review delivery channels'],
      },
      {
        id: 'orchestration',
        title: 'Orchestration',
        summary: 'Stage multiple local agents with explicit roles, context budgets, handoffs, and finish lines.',
        status: 'native-state',
        icon: 'rectangle.3.group',
        accent: 'cyan',
        localFirst: true,
        actions: ['Assign roles', 'Set context lanes', 'Track handoffs', 'Collect outcomes'],
      },
      {
        id: 'assistant-crew',
        title: 'Assistant Crew',
        summary: 'Give RoachClaw recurring check-ins, scoped roles, and time-boxed follow-through without hiding a daemon in the walls.',
        status: 'native-state',
        icon: 'person.3.sequence',
        accent: 'bronze',
        localFirst: true,
        actions: ['Create check-in', 'Assign role', 'Run now', 'Review status'],
      },
      {
        id: 'time-context',
        title: 'Time Context',
        summary: 'Keep user timezone and local clock context explicit for scheduling, reminders, and relative-date prompts.',
        status: 'native-state',
        icon: 'clock.badge.checkmark',
        accent: 'bronze',
        localFirst: true,
        actions: ['Set timezone', 'Attach prompt clock', 'Refresh scheduler'],
      },
      {
        id: 'backup-restore',
        title: 'Backup + Restore',
        summary: 'Snapshot RoachClaw state, scrub secrets, and make moving machines boring in the best possible way.',
        status: 'native-state',
        icon: 'externaldrive.badge.timemachine',
        accent: 'cyan',
        localFirst: true,
        actions: ['Create snapshot', 'Export state', 'Inspect scrubbed copy', 'Restore lane'],
      },
    ],
  }
}

function roachClawNativeFeatureGroups({ hasLocalModels, localReady, agentReady } = {}) {
  const runtimeStatus = localReady ? 'native-ready' : 'runtime-warmup'
  const agentStatus = agentReady ? 'native-ready' : 'agent-warmup'
  const modelStatus = hasLocalModels ? 'native-ready' : 'needs-model'

  return [
    {
      id: 'chat',
      title: 'Chat',
      summary: 'Local and provider-backed conversations with sessions, streaming, presets, attachments, run replay, and context controls.',
      status: runtimeStatus,
      nativeSurface: 'RoachClaw',
      capabilities: ['sessions', 'streaming', 'presets', 'attachments', 'provider-routes', 'detached-runs'],
    },
    {
      id: 'session-board',
      title: 'Session Board',
      summary: 'Native session history, detached run replay, transcript save/export, and context restore without a web shell.',
      status: 'native-state',
      nativeSurface: 'RoachClaw',
      capabilities: ['session-history', 'run-replay', 'transcript-save', 'context-restore', 'branch-resume'],
    },
    {
      id: 'session-history',
      title: 'Session History',
      summary: 'Fork, compact, export, rename, archive, auto-sort, and restore conversations without a browser-backed history pile.',
      status: 'native-state',
      nativeSurface: 'RoachClaw',
      capabilities: ['fork-session', 'compact-session', 'export-session', 'auto-sort', 'message-edit', 'archive'],
    },
    {
      id: 'agent-tools',
      title: 'Agent Tools',
      summary: 'Tool-running workbench for shell, files, MCP, app actions, indexed tool cards, and scoped local context.',
      status: agentStatus,
      nativeSurface: 'RoachClaw',
      capabilities: ['shell-actions', 'file-actions', 'mcp-tools', 'scoped-context', 'action-approval', 'tool-index'],
    },
    {
      id: 'cookbook',
      title: 'Cookbook',
      summary: 'Hardware-aware model recommendations with quantized/MoE sizing, download lanes, cache layout, serve plans, and degraded-state reporting.',
      status: modelStatus,
      nativeSurface: 'Runtime',
      capabilities: [
        'hardware-scan',
        'fit-scoring',
        'quant-aware-sizing',
        'moe-active-params',
        'model-packs',
        'download-queue',
        'cache-layout',
        'serve-plan',
        'serve-schedule',
        'progress-signal',
      ],
    },
    {
      id: 'workspace-browser',
      title: 'Workspace Browser',
      summary: 'Native project-folder browser for Dev and RoachClaw context, with hidden entries and symlinks skipped by default.',
      status: 'native-state',
      nativeSurface: 'Dev',
      capabilities: ['directory-browse', 'safe-folder-context', 'pin-project', 'attach-to-agent'],
    },
    {
      id: 'deep-research',
      title: 'Deep Research',
      summary: 'Multi-step source gathering, extraction controls, synthesis, citations, and vault-ready reports.',
      status: agentStatus,
      nativeSurface: 'RoachClaw',
      capabilities: ['research-plan', 'source-gathering', 'source-synthesis', 'citations', 'visual-report'],
    },
    {
      id: 'compare',
      title: 'Compare',
      summary: 'Blind model comparison with paired prompts, scoring, reveal, and saved winners.',
      status: hasLocalModels ? 'native-ready' : 'needs-second-model',
      nativeSurface: 'RoachClaw',
      capabilities: ['blind-test', 'scoreboard', 'model-reveal', 'winner-save'],
    },
    {
      id: 'model-bench',
      title: 'Model Bench',
      summary: 'A native bench for fit scoring, side-by-side testing, saved winners, and Apple Silicon serve plans.',
      status: modelStatus,
      nativeSurface: 'Runtime',
      capabilities: ['fit-score', 'blind-compare', 'serve-plan', 'winner-history', 'model-pack-route'],
    },
    {
      id: 'model-providers',
      title: 'Model Providers',
      summary: 'Probe local and remote-compatible endpoints, curate models, hide noisy routes, and keep defaults explicit.',
      status: 'native-ready',
      nativeSurface: 'Runtime',
      capabilities: ['endpoint-probing', 'provider-curation', 'model-hide-list', 'default-route', 'context-window-estimates'],
    },
    {
      id: 'documents',
      title: 'Documents',
      summary: 'Markdown, HTML, CSV, PDF, ebook, and vault document help with rewrite, summarize, fill, export, and read-aloud actions.',
      status: 'native-ready',
      nativeSurface: 'Vault',
      capabilities: ['markdown', 'pdf', 'ebook-reader', 'ai-edits', 'export', 'read-aloud'],
    },
    {
      id: 'migration-document-tools',
      title: 'Migration + Document Tools',
      summary: 'Office import, active document context, edit/suggestion blocks, route validators, migration manifests, and cookbook output classification rewritten as native RoachNet state.',
      status: 'native-state',
      nativeSurface: 'Vault + RoachClaw',
      capabilities: [
        'office-attachment-docs',
        'active-document-context',
        'edit-suggestion-blocks',
        'agent-migration-manifest',
        'route-validators',
        'cookbook-output-classifier',
        'optional-dependency-shims',
        'reminder-personas',
        'vllm-recipe-import',
        'model-release-date-backfill',
      ],
    },
    {
      id: 'memory-skills',
      title: 'RoachBrain + Skills',
      summary: 'Persistent memories, compacted context, skill extraction, import/export, audits, and retrieval that stays inside RoachNet.',
      status: 'native-ready',
      nativeSurface: 'RoachBrain',
      capabilities: ['memory', 'skills', 'context-compaction', 'audit', 'retrieval', 'import-export'],
    },
    {
      id: 'memory-provider',
      title: 'Memory Provider',
      summary: 'Provider-neutral memory contract with RoachBrain native memory always available and external systems opt-in.',
      status: 'native-state',
      nativeSurface: 'RoachBrain',
      capabilities: ['provider-contract', 'remember', 'recall', 'list', 'delete', 'tool-schemas'],
    },
    {
      id: 'embedding-lanes',
      title: 'Embedding Lanes',
      summary: 'Separate local and custom embedding metadata with dimensions, fingerprints, reset safety, stats, and health.',
      status: 'native-state',
      nativeSurface: 'RoachBrain',
      capabilities: ['local-lane', 'custom-lane', 'dimension-fingerprint', 'safe-reset', 'health-stats'],
    },
    {
      id: 'email',
      title: 'Mail',
      summary: 'Inbox triage, summaries, urgency cues, reply drafts, contact context, and account-scoped routing.',
      status: 'planned-native',
      nativeSurface: 'RoachClaw',
      capabilities: ['imap-sync', 'smtp-drafts', 'triage', 'contact-context', 'reply-routing'],
    },
    {
      id: 'notes-tasks',
      title: 'Notes + Tasks',
      summary: 'Quick notes, reminders, checklists, scheduled agent tasks, and delivery channels.',
      status: 'planned-native',
      nativeSurface: 'Home',
      capabilities: ['notes', 'checklists', 'reminders', 'scheduled-runs', 'notifications'],
    },
    {
      id: 'calendar',
      title: 'Calendar',
      summary: 'Local calendar planning with import/export, recurrence, reminders, and optional CalDAV sync.',
      status: 'planned-native',
      nativeSurface: 'Maps',
      capabilities: ['calendar', 'recurrence', 'ics-import-export', 'caldav', 'reminders'],
    },
    {
      id: 'search-rag',
      title: 'Search + RAG',
      summary: 'Local document indexing, web search provider routing, ranking, caching, and source-grounded answers.',
      status: 'native-ready',
      nativeSurface: 'Vault',
      capabilities: ['vault-index', 'web-search', 'ranking', 'source-cache', 'context-retrieval'],
    },
    {
      id: 'voice',
      title: 'Voice',
      summary: 'RoachSpeech dictation, transcription, read-aloud, voice profiles, and optional model packs.',
      status: 'native-ready',
      nativeSurface: 'RoachSpeech',
      capabilities: ['stt', 'tts', 'voice-profiles', 'vault-transcripts', 'model-packs'],
    },
    {
      id: 'gallery-editor',
      title: 'Gallery + Editor',
      summary: 'Media import, albums, metadata tags, image cleanup, and local-first generated asset handling.',
      status: 'planned-native',
      nativeSurface: 'Vault',
      capabilities: ['gallery', 'albums', 'metadata-tags', 'image-tools', 'asset-export'],
    },
    {
      id: 'security',
      title: 'Security + Accounts',
      summary: 'Local auth boundaries, token gates, scoped tools, action approval, and private-by-default runtime posture.',
      status: 'native-ready',
      nativeSurface: 'Settings',
      capabilities: ['scoped-tools', 'api-tokens', 'pairing', 'action-approval', 'local-first'],
    },
    {
      id: 'provider-security',
      title: 'Provider Security',
      summary: 'TLS CA-bundle metadata, public URL validation, OAuth flow state, and scoped tool exposure for user-owned providers.',
      status: 'native-state',
      nativeSurface: 'Settings',
      capabilities: ['tls-ca-bundle', 'url-safety', 'oauth-flow-state', 'token-redaction', 'scoped-tool-bridge'],
    },
    {
      id: 'tool-policy',
      title: 'Tool Policy',
      summary: 'Guide-only detection, disabled-tool state, hidden-tool display, and enforcement metadata for native RoachClaw.',
      status: 'native-state',
      nativeSurface: 'RoachClaw',
      capabilities: ['guide-only-detection', 'disabled-tools', 'hidden-tools', 'mcp-disable', 'enforcement-metadata'],
    },
    {
      id: 'mobile',
      title: 'iOS Companion',
      summary: 'Runtime checks, vault reads, app installs, RoachTail pairing, and phone-sized control surfaces.',
      status: 'native-ready',
      nativeSurface: 'iOS',
      capabilities: ['runtime-status', 'vault-reads', 'app-installs', 'roachtail', 'mobile-ui'],
    },
    {
      id: 'contacts',
      title: 'Contacts',
      summary: 'Contact context, reply recipients, account ownership, and local relationship hints without a hosted CRM dependency.',
      status: 'planned-native',
      nativeSurface: 'RoachClaw',
      capabilities: ['contact-context', 'reply-recipients', 'owner-scope', 'local-address-book'],
    },
    {
      id: 'diagnostics',
      title: 'Diagnostics',
      summary: 'Provider probes, degraded-state reporting, runtime health, setup warnings, and evidence users can act on.',
      status: 'native-ready',
      nativeSurface: 'Runtime',
      capabilities: ['provider-probes', 'health-report', 'service-health-rollup', 'secret-safe-probes', 'bounded-timeouts', 'degraded-services', 'setup-hints'],
    },
    {
      id: 'preferences',
      title: 'Preferences + Themes',
      summary: 'Settings, presets, theme choices, model sorting, and safe scrub/export flows owned by the native shell.',
      status: 'native-ready',
      nativeSurface: 'Settings',
      capabilities: ['settings', 'presets', 'themes', 'model-sort', 'settings-scrub'],
    },
    {
      id: 'theme-studio',
      title: 'Theme Studio',
      summary: 'Native palette, density, motion, and appearance controls for a shell that feels tuned instead of skinned.',
      status: 'native-ready',
      nativeSurface: 'Settings',
      capabilities: ['palette', 'density', 'motion', 'contrast', 'settings-export'],
    },
    {
      id: 'uploads-personal-docs',
      title: 'Uploads + Personal Docs',
      summary: 'Vision/PDF uploads, personal document indexing, ownership isolation, and vault-safe import paths.',
      status: 'native-ready',
      nativeSurface: 'Vault',
      capabilities: ['file-uploads', 'vision', 'pdf-index', 'owner-isolation', 'vault-import'],
    },
    {
      id: 'webhooks-integrations',
      title: 'Webhooks + Integrations',
      summary: 'Provider routes, inbound hooks, local API tokens, user-owned cloud keys, remote handoffs, and scoped integration secrets.',
      status: 'planned-native',
      nativeSurface: 'Runtime',
      capabilities: ['webhooks', 'provider-routes', 'api-tokens', 'optional-cloud-provider-keys', 'secret-storage', 'integration-audit'],
    },
    {
      id: 'background-jobs',
      title: 'Background Jobs',
      summary: 'Scheduled tasks, session delivery, reminders, polling, local event counters, and long-running work with visible status.',
      status: 'native-state',
      nativeSurface: 'Home',
      capabilities: ['scheduler', 'session-delivery', 'polling', 'reminders', 'job-status', 'event-counters', 'run-history'],
    },
    {
      id: 'assistant-crew',
      title: 'Assistant Crew',
      summary: 'Recurring check-ins, crew roles, run-now controls, time zones, and status ledgers folded into RoachClaw.',
      status: 'native-state',
      nativeSurface: 'RoachClaw',
      capabilities: ['crew-settings', 'scheduled-check-ins', 'run-now', 'status-ledger', 'timezone-list'],
    },
    {
      id: 'user-time',
      title: 'User Time',
      summary: 'Local timezone and clock context for schedulers, reminders, and RoachClaw prompts that use relative dates.',
      status: 'native-state',
      nativeSurface: 'Settings',
      capabilities: ['timezone-context', 'utc-offset', 'prompt-clock', 'scheduler-context'],
    },
    {
      id: 'orchestration',
      title: 'Orchestration',
      summary: 'Multi-agent planning with explicit roles, context budgets, handoff state, and Activity Monitor-style run visibility.',
      status: 'native-state',
      nativeSurface: 'RoachClaw',
      capabilities: ['agent-runs', 'role-routing', 'context-budgets', 'handoffs', 'activity-monitor'],
    },
    {
      id: 'visual-reports',
      title: 'Visual Reports',
      summary: 'Research briefs, source evidence, rendered summaries, and exportable reports that can be saved to the vault.',
      status: 'planned-native',
      nativeSurface: 'Vault',
      capabilities: ['report-rendering', 'source-evidence', 'exports', 'vault-save'],
    },
    {
      id: 'signatures',
      title: 'Signatures',
      summary: 'Saved signatures for documents, mail drafts, and vault notes, with local storage and explicit export paths.',
      status: 'native-state',
      nativeSurface: 'Vault',
      capabilities: ['signature-store', 'document-signing', 'mail-signatures', 'vault-notes'],
    },
    {
      id: 'backup-restore',
      title: 'Backup + Restore',
      summary: 'Export/import RoachClaw state, scrub secrets, snapshot local lanes, and make machine moves inspectable.',
      status: 'native-state',
      nativeSurface: 'Settings',
      capabilities: ['state-export', 'state-import', 'secret-scrub', 'snapshots', 'selective-restore'],
    },
    {
      id: 'local-api-keys',
      title: 'Local API Keys',
      summary: 'Local integration keys and webhook secrets are created with one-time reveal, hashed storage, and owner-scoped access.',
      status: 'native-state',
      nativeSurface: 'Settings',
      capabilities: ['one-time-reveal', 'hash-only-storage', 'owner-scope', 'token-revoke'],
    },
    {
      id: 'font-emoji-assets',
      title: 'Font + Emoji Assets',
      summary: 'Custom font discovery and emoji rendering stay local so the shell can look right without reaching for a CDN.',
      status: 'native-ready',
      nativeSurface: 'RoachNet',
      capabilities: ['font-discovery', 'emoji-rendering', 'offline-assets', 'accessibility-labels'],
    },
    {
      id: 'housekeeping',
      title: 'Housekeeping',
      summary: 'Cleanup previews, upload cleanup, rate limiting, degraded-state checks, and safe admin reset paths.',
      status: 'native-state',
      nativeSurface: 'Runtime',
      capabilities: ['cleanup-preview', 'upload-cleanup', 'rate-limits', 'degraded-state', 'admin-reset'],
    },
    {
      id: 'admin-recovery',
      title: 'Admin Recovery',
      summary: 'First-run admin setup, ownerless data claims, wipe/reset gates, and recovery flows that stay explicit.',
      status: 'native-ready',
      nativeSurface: 'Settings',
      capabilities: ['first-run-admin', 'ownerless-claim', 'wipe-gate', 'recovery'],
    },
  ]
}

function roachClawReferenceModules() {
  return [
    { id: 'core-auth', category: 'core', source: 'core/auth.py', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'core-database', category: 'core', source: 'core/database.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'core-middleware', category: 'core', source: 'core/middleware.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'core-models', category: 'core', source: 'core/models.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'core-session-manager', category: 'core', source: 'core/session_manager.py', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'core-atomic-io', category: 'core', source: 'core/atomic_io.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'auth-routes', category: 'route', source: 'routes/auth_routes.py', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'admin-wipe-routes', category: 'route', source: 'routes/admin_wipe_routes.py', nativeSurface: 'Settings', status: 'planned-native' },
    { id: 'api-token-routes', category: 'route', source: 'routes/api_token_routes.py', nativeSurface: 'Settings', status: 'native-state' },
    { id: 'assistant-routes', category: 'route', source: 'routes/assistant_routes.py', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'backup-routes', category: 'route', source: 'routes/backup_routes.py', nativeSurface: 'Settings', status: 'native-state' },
    { id: 'calendar-routes', category: 'route', source: 'routes/calendar_routes.py', nativeSurface: 'Maps', status: 'planned-native' },
    { id: 'chat-routes', category: 'route', source: 'routes/chat_routes.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'cleanup-routes', category: 'route', source: 'routes/cleanup_routes.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'compare-routes', category: 'route', source: 'routes/compare_routes.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'contacts-routes', category: 'route', source: 'routes/contacts_routes.py', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'cookbook-routes', category: 'route', source: 'routes/cookbook_routes.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'codex-routes', category: 'route', source: 'routes/codex_routes.py', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'copilot-routes', category: 'route', source: 'routes/copilot_routes.py', nativeSurface: 'Settings', status: 'planned-optional-user-provider' },
    { id: 'diagnostics-routes', category: 'route', source: 'routes/diagnostics_routes.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'document-routes', category: 'route', source: 'routes/document_routes.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'editor-draft-routes', category: 'route', source: 'routes/editor_draft_routes.py', nativeSurface: 'Vault', status: 'native-state' },
    { id: 'email-routes', category: 'route', source: 'routes/email_routes.py', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'email-pollers', category: 'route', source: 'routes/email_pollers.py', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'embedding-routes', category: 'route', source: 'routes/embedding_routes.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'emoji-routes', category: 'route', source: 'routes/emoji_routes.py', nativeSurface: 'RoachNet', status: 'native-ready' },
    { id: 'font-routes', category: 'route', source: 'routes/font_routes.py', nativeSurface: 'RoachNet', status: 'native-ready' },
    { id: 'gallery-routes', category: 'route', source: 'routes/gallery_routes.py', nativeSurface: 'Vault', status: 'planned-native' },
    { id: 'history-routes', category: 'route', source: 'routes/history_routes.py', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'hwfit-routes', category: 'route', source: 'routes/hwfit_routes.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'mcp-routes', category: 'route', source: 'routes/mcp_routes.py', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'memory-routes', category: 'route', source: 'routes/memory_routes.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'model-routes', category: 'route', source: 'routes/model_routes.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'note-routes', category: 'route', source: 'routes/note_routes.py', nativeSurface: 'Home', status: 'planned-native' },
    { id: 'personal-routes', category: 'route', source: 'routes/personal_routes.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'prefs-routes', category: 'route', source: 'routes/prefs_routes.py', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'preset-routes', category: 'route', source: 'routes/preset_routes.py', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'research-routes', category: 'route', source: 'routes/research_routes.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'search-routes', category: 'route', source: 'routes/search_routes.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'session-routes', category: 'route', source: 'routes/session_routes.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'shell-routes', category: 'route', source: 'routes/shell_routes.py', nativeSurface: 'Dev', status: 'native-ready' },
    { id: 'signature-routes', category: 'route', source: 'routes/signature_routes.py', nativeSurface: 'Vault', status: 'native-state' },
    { id: 'skills-routes', category: 'route', source: 'routes/skills_routes.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'stt-routes', category: 'route', source: 'routes/stt_routes.py', nativeSurface: 'RoachSpeech', status: 'native-ready' },
    { id: 'task-routes', category: 'route', source: 'routes/task_routes.py', nativeSurface: 'Home', status: 'planned-native' },
    { id: 'tts-routes', category: 'route', source: 'routes/tts_routes.py', nativeSurface: 'RoachSpeech', status: 'native-ready' },
    { id: 'upload-routes', category: 'route', source: 'routes/upload_routes.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'vault-routes', category: 'route', source: 'routes/vault_routes.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'webhook-routes', category: 'route', source: 'routes/webhook_routes.py', nativeSurface: 'Runtime', status: 'planned-native' },
    { id: 'workspace-routes', category: 'route', source: 'routes/workspace_routes.py', nativeSurface: 'Dev', status: 'restored-upstream-native-rewrite' },
    { id: 'route-validators', category: 'route', source: 'routes/_validators.py', nativeSurface: 'Runtime + Settings', status: 'native-ready' },
    { id: 'cookbook-output-route', category: 'route', source: 'routes/cookbook_output.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'action-intents', category: 'source', source: 'src/action_intents.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'agent-loop', category: 'source', source: 'src/agent_loop.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'agent-runs', category: 'source', source: 'src/agent_runs.py', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'agent-tools-package', category: 'source', source: 'src/agent_tools/__init__.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'agent-document-tools', category: 'source', source: 'src/agent_tools/document_tools.py', nativeSurface: 'Vault + RoachClaw', status: 'native-state' },
    { id: 'agent-filesystem-tools', category: 'source', source: 'src/agent_tools/filesystem_tools.py', nativeSurface: 'Dev + Vault', status: 'native-ready' },
    { id: 'agent-subprocess-tools', category: 'source', source: 'src/agent_tools/subprocess_tools.py', nativeSurface: 'Dev + Runtime', status: 'native-ready' },
    { id: 'agent-web-tools', category: 'source', source: 'src/agent_tools/web_tools.py', nativeSurface: 'RoachClaw Web', status: 'native-state' },
    { id: 'api-key-manager', category: 'source', source: 'src/api_key_manager.py', nativeSurface: 'Settings', status: 'native-state' },
    { id: 'assistant-log', category: 'source', source: 'src/assistant_log.py', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'background-jobs', category: 'source', source: 'src/bg_jobs.py', nativeSurface: 'Home', status: 'planned-native' },
    { id: 'background-monitor', category: 'source', source: 'src/bg_monitor.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'builtin-actions', category: 'source', source: 'src/builtin_actions.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'builtin-mcp', category: 'source', source: 'src/builtin_mcp.py', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'caldav-sync', category: 'source', source: 'src/caldav_sync.py', nativeSurface: 'Maps', status: 'planned-native' },
    { id: 'chat-handler', category: 'source', source: 'src/chat_handler.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'chat-processor', category: 'source', source: 'src/chat_processor.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'chroma-client', category: 'source', source: 'src/chroma_client.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'cleanup-service', category: 'source', source: 'src/cleanup_service.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'context-compactor', category: 'source', source: 'src/context_compactor.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'cookbook-serve-lifecycle', category: 'source', source: 'src/cookbook_serve_lifecycle.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'copilot-provider', category: 'source', source: 'src/copilot.py', nativeSurface: 'Settings', status: 'planned-optional-user-provider' },
    { id: 'deep-research', category: 'source', source: 'src/deep_research.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'document-actions', category: 'source', source: 'src/document_actions.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'document-processor', category: 'source', source: 'src/document_processor.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'embedding-lanes', category: 'source', source: 'src/embedding_lanes.py', nativeSurface: 'RoachBrain', status: 'native-state' },
    { id: 'embeddings', category: 'source', source: 'src/embeddings.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'endpoint-resolver', category: 'source', source: 'src/endpoint_resolver.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'event-bus', category: 'source', source: 'src/event_bus.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'goal-extractor', category: 'source', source: 'src/goal_based_extractor.py', nativeSurface: 'RoachBrain', status: 'native-state' },
    { id: 'integrations', category: 'source', source: 'src/integrations.py', nativeSurface: 'Runtime', status: 'planned-native' },
    { id: 'llm-core', category: 'source', source: 'src/llm_core.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'mcp-manager', category: 'source', source: 'src/mcp_manager.py', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'memory-source', category: 'source', source: 'src/memory.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'memory-provider', category: 'source', source: 'src/memory_provider.py', nativeSurface: 'RoachBrain', status: 'native-state' },
    { id: 'mcp-oauth', category: 'source', source: 'src/mcp_oauth.py', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'model-context', category: 'source', source: 'src/model_context.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'model-discovery', category: 'source', source: 'src/model_discovery.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'pdf-forms', category: 'source', source: 'src/pdf_forms.py', nativeSurface: 'Vault', status: 'native-state' },
    { id: 'pdf-runtime', category: 'source', source: 'src/pdf_runtime.py', nativeSurface: 'Vault', status: 'native-state' },
    { id: 'personal-docs', category: 'source', source: 'src/personal_docs.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'presets', category: 'source', source: 'src/preset_manager.py', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'prompt-security', category: 'source', source: 'src/prompt_security.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'rag-manager', category: 'source', source: 'src/rag_manager.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'rag-singleton', category: 'source', source: 'src/rag_singleton.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'rate-limiter', category: 'source', source: 'src/rate_limiter.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'research-handler', category: 'source', source: 'src/research_handler.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'search-ranking', category: 'source', source: 'src/search/ranking.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'secret-storage', category: 'source', source: 'src/secret_storage.py', nativeSurface: 'Settings', status: 'planned-native' },
    { id: 'settings-source', category: 'source', source: 'src/settings.py', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'settings-scrub', category: 'source', source: 'src/settings_scrub.py', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'service-health', category: 'source', source: 'src/service_health.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'office-doc', category: 'source', source: 'src/office_doc.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'optional-deps', category: 'source', source: 'src/optional_deps.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'reminder-personas', category: 'source', source: 'src/reminder_personas.py', nativeSurface: 'Home + RoachClaw', status: 'native-state' },
    { id: 'session-actions', category: 'source', source: 'src/session_actions.py', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'tls-overrides', category: 'source', source: 'src/tls_overrides.py', nativeSurface: 'Settings', status: 'native-state' },
    { id: 'task-scheduler', category: 'source', source: 'src/task_scheduler.py', nativeSurface: 'Home', status: 'planned-native' },
    { id: 'teacher-escalation', category: 'source', source: 'src/teacher_escalation.py', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'tool-execution', category: 'source', source: 'src/tool_execution.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'tool-index', category: 'source', source: 'src/tool_index.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'tool-policy', category: 'source', source: 'src/tool_policy.py', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'tool-security', category: 'source', source: 'src/tool_security.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'topic-analyzer', category: 'source', source: 'src/topic_analyzer.py', nativeSurface: 'RoachBrain', status: 'native-state' },
    { id: 'upload-handler', category: 'source', source: 'src/upload_handler.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'upload-limits', category: 'source', source: 'src/upload_limits.py', nativeSurface: 'Vault', status: 'native-state' },
    { id: 'url-security', category: 'source', source: 'src/url_security.py', nativeSurface: 'Settings', status: 'native-state' },
    { id: 'url-safety', category: 'source', source: 'src/url_safety.py', nativeSurface: 'Settings', status: 'native-state' },
    { id: 'user-time', category: 'source', source: 'src/user_time.py', nativeSurface: 'Settings', status: 'native-state' },
    { id: 'visual-report', category: 'source', source: 'src/visual_report.py', nativeSurface: 'Vault', status: 'planned-native' },
    { id: 'webhook-manager', category: 'source', source: 'src/webhook_manager.py', nativeSurface: 'Runtime', status: 'planned-native' },
    { id: 'docs-service', category: 'service', source: 'services/docs/service.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'faces-service', category: 'service', source: 'services/faces/__init__.py', nativeSurface: 'Vault', status: 'planned-native' },
    { id: 'hwfit-fit', category: 'service', source: 'services/hwfit/fit.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'hwfit-hardware', category: 'service', source: 'services/hwfit/hardware.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'hwfit-image-models', category: 'service', source: 'services/hwfit/image_models.py', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'hwfit-models', category: 'service', source: 'services/hwfit/models.py', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'memory-service', category: 'service', source: 'services/memory/service.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'memory-vector', category: 'service', source: 'services/memory/memory_vector.py', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'research-service', category: 'service', source: 'services/research/service.py', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'search-service', category: 'service', source: 'services/search/service.py', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'shell-service', category: 'service', source: 'services/shell/service.py', nativeSurface: 'Dev', status: 'native-ready' },
    { id: 'stt-service', category: 'service', source: 'services/stt/stt_service.py', nativeSurface: 'RoachSpeech', status: 'native-ready' },
    { id: 'tts-service', category: 'service', source: 'services/tts/tts_service.py', nativeSurface: 'RoachSpeech', status: 'native-ready' },
    { id: 'cookbook-ui', category: 'web', source: 'static/js/cookbook.js', nativeSurface: 'Runtime', status: 'native-ready' },
    { id: 'cookbook-progress-signal-ui', category: 'web', source: 'static/js/cookbookProgressSignal.js', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'cookbook-schedule-ui', category: 'web', source: 'static/js/cookbookSchedule.js', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'assistant-ui', category: 'web', source: 'static/js/assistant.js', nativeSurface: 'RoachClaw', status: 'native-state' },
    { id: 'calendar-ui', category: 'web', source: 'static/js/calendar.js', nativeSurface: 'Maps', status: 'planned-native' },
    { id: 'chat-ui', category: 'web', source: 'static/js/chat.js', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'compare-ui', category: 'web', source: 'static/js/models.js', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'compare-scoreboard-ui', category: 'web', source: 'static/js/compare/scoreboard.js', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'compare-stream-ui', category: 'web', source: 'static/js/compare/stream.js', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'compare-vote-ui', category: 'web', source: 'static/js/compare/vote.js', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'document-ui', category: 'web', source: 'static/js/document.js', nativeSurface: 'Vault', status: 'native-ready' },
    { id: 'emoji-shortcodes-ui', category: 'web', source: 'static/js/emojiShortcodes.js', nativeSurface: 'RoachNet', status: 'native-state' },
    { id: 'gallery-ui', category: 'web', source: 'static/js/gallery.js', nativeSurface: 'Vault', status: 'planned-native' },
    { id: 'email-ui', category: 'web', source: 'static/js/emailLibrary.js', nativeSurface: 'RoachClaw', status: 'planned-native' },
    { id: 'memory-ui', category: 'web', source: 'static/js/memory.js', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'notes-ui', category: 'web', source: 'static/js/notes.js', nativeSurface: 'Home', status: 'planned-native' },
    { id: 'research-ui', category: 'web', source: 'static/js/researchSynapse.js', nativeSurface: 'RoachClaw', status: 'native-ready' },
    { id: 'settings-ui', category: 'web', source: 'static/js/settings.js', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'skills-ui', category: 'web', source: 'static/js/skills.js', nativeSurface: 'RoachBrain', status: 'native-ready' },
    { id: 'streaming-segmenter-ui', category: 'web', source: 'static/js/streamingSegmenter.js', nativeSurface: 'RoachClaw Web', status: 'native-state' },
    { id: 'streaming-renderer-ui', category: 'web', source: 'static/js/streamingRenderer.js', nativeSurface: 'RoachClaw Web', status: 'native-state' },
    { id: 'task-ui', category: 'web', source: 'static/js/tasks.js', nativeSurface: 'Home', status: 'planned-native' },
    { id: 'theme-ui', category: 'web', source: 'static/js/theme.js', nativeSurface: 'Settings', status: 'native-ready' },
    { id: 'tts-ui', category: 'web', source: 'static/js/tts-ai.js', nativeSurface: 'RoachSpeech', status: 'native-ready' },
    { id: 'ui-shell', category: 'web', source: 'static/js/ui.js', nativeSurface: 'RoachNet', status: 'native-ready' },
    { id: 'workspace-ui', category: 'web', source: 'static/js/workspace.js', nativeSurface: 'Dev', status: 'native-state' },
    { id: 'cookbook-deps-recipes-ui', category: 'web', source: 'static/js/cookbook-deps-recipes.js', nativeSurface: 'Runtime', status: 'native-state' },
    { id: 'agent-migration-manifest', category: 'script', source: 'scripts/agent_migration_manifest.py', nativeSurface: 'Settings + RoachBrain', status: 'native-ready' },
    { id: 'backfill-model-release-dates', category: 'script', source: 'scripts/backfill_model_release_dates.py', nativeSurface: 'Runtime + App Store', status: 'planned-native' },
    { id: 'import-vllm-recipes', category: 'script', source: 'scripts/import_from_vllm_recipes.py', nativeSurface: 'Runtime + App Store', status: 'planned-native' },
  ]
}

function roachClawReferenceInventory() {
  const coverageGroups = [
    {
      id: 'routes',
      label: 'Routes + Helpers',
      prefix: 'routes/',
      fileCount: 54,
      nativeSurface: 'Native API + Swift surfaces',
      status: 'tracked-native-rewrite',
      notes: 'Every route and route helper is treated as a RoachNet bridge, view, or operation contract.',
    },
    {
      id: 'core',
      label: 'Core Runtime',
      prefix: 'core/',
      fileCount: 10,
      nativeSurface: 'Runtime + Settings',
      status: 'tracked-native-rewrite',
      notes: 'Auth, database, sessions, platform behavior, exceptions, and constants map to the contained runtime.',
    },
    {
      id: 'source',
      label: 'Source Modules',
      prefix: 'src/',
      fileCount: 108,
      nativeSurface: 'RoachClaw + RoachBrain + Vault',
      status: 'tracked-native-rewrite',
      notes: 'Agent loops, tools, RAG, documents, settings scrub, uploads, and reports are native feature obligations.',
    },
    {
      id: 'services',
      label: 'Services',
      prefix: 'services/',
      fileCount: 40,
      nativeSurface: 'Runtime + RoachSpeech + Vault',
      status: 'tracked-native-rewrite',
      notes: 'Docs, model fit, memory, research, search, shell, STT, TTS, and media services become RoachNet-native lanes.',
    },
    {
      id: 'mcp-servers',
      label: 'MCP Servers',
      prefix: 'mcp_servers/',
      fileCount: 5,
      nativeSurface: 'RoachClaw Tools',
      status: 'tracked-native-rewrite',
      notes: 'Email, image generation, memory, and RAG MCP behavior maps to scoped native tools.',
    },
    {
      id: 'scripts',
      label: 'CLI Scripts',
      prefix: 'scripts/',
      fileCount: 43,
      nativeSurface: 'Command Deck + Runtime',
      status: 'tracked-native-rewrite',
      notes: 'Operational scripts become command palette actions, runtime jobs, or documented non-shipping migration references.',
    },
    {
      id: 'companion',
      label: 'Companion Pairing',
      prefix: 'companion/',
      fileCount: 4,
      nativeSurface: 'RoachNet iOS + RoachTail',
      status: 'tracked-native-rewrite',
      notes: 'Pairing and companion routes map to the iOS app and RoachTail local control plane.',
    },
    {
      id: 'static-js',
      label: 'Web Interaction Modules',
      prefix: 'static/js/',
      fileCount: 152,
      nativeSurface: 'SwiftUI + RoachClaw Web',
      status: 'tracked-native-rewrite',
      notes: 'WebUI interaction behavior is either rebuilt in SwiftUI or folded into the RoachClaw web surface without shipping the upstream UI.',
    },
  ]
  const functionalFileCount = coverageGroups.reduce((sum, group) => sum + group.fileCount, 0)

  return {
    schema: 'org.roachnet.roachclaw.github-reference-inventory.v1',
    repository: roachClawReferenceRepository,
    commit: roachClawReferenceCommit,
    latestSeenCommit: roachClawReferenceLatestCommit,
    sourceKind: 'github-upstream',
    observedFileCount: 1141,
    functionalFileCount,
    coverageGroups,
    nonShippingPolicy: 'Python, Flask, WebUI, shell scripts, Docker, tests, and docs are reference material only; RoachNet ships native SwiftUI, Core ML, Foundation, AVFoundation, Network, and contained runtime rewrites.',
  }
}

function roachClawParityCoverage(options = {}) {
  const featureGroups = roachClawNativeFeatureGroups(options)
  const modules = roachClawReferenceModules()
  const inventory = roachClawReferenceInventory()
  const countsByStatus = (items) => items.reduce((counts, item) => {
    counts[item.status] = (counts[item.status] || 0) + 1
    return counts
  }, {})
  const requiredFamilies = [
    'chat',
    'session-board',
    'session-history',
    'agent-tools',
    'cookbook',
    'workspace-browser',
    'deep-research',
    'compare',
    'model-bench',
    'model-providers',
    'documents',
    'migration-document-tools',
    'memory-skills',
    'memory-provider',
    'embedding-lanes',
    'email',
    'notes-tasks',
    'calendar',
    'search-rag',
    'voice',
    'gallery-editor',
    'security',
    'provider-security',
    'tool-policy',
    'mobile',
    'contacts',
    'diagnostics',
    'preferences',
    'theme-studio',
    'uploads-personal-docs',
    'webhooks-integrations',
    'background-jobs',
    'assistant-crew',
    'user-time',
    'orchestration',
    'visual-reports',
    'signatures',
    'backup-restore',
    'local-api-keys',
    'font-emoji-assets',
    'housekeeping',
    'admin-recovery',
  ]
  const presentFamilies = new Set(featureGroups.map((feature) => feature.id))

  return {
    schema: 'org.roachnet.roachclaw.reference-coverage.v1',
    referenceCommit: roachClawReferenceCommit,
    latestSeenCommit: roachClawReferenceLatestCommit,
    repository: roachClawReferenceRepository,
    sourceKind: 'github-upstream',
    posture: 'native-rewrite-no-python-webui-dependency',
    requiredFamilies,
    missingFamilies: requiredFamilies.filter((id) => !presentFamilies.has(id)),
    observedFileCount: inventory.observedFileCount,
    functionalFileCount: inventory.functionalFileCount,
    inventoryGroupCount: inventory.coverageGroups.length,
    inventoryCoverageMode: 'full-github-functional-surface',
    featureGroupCount: featureGroups.length,
    moduleCount: modules.length,
    featureStatusCounts: countsByStatus(featureGroups),
    moduleStatusCounts: countsByStatus(modules),
  }
}

function accountState() {
  return {
    linked: false,
    provider: 'local',
    portalUrl: 'https://roachnet.org/',
    accountId: null,
    email: null,
    displayName: null,
    status: 'local-only',
    settingsSyncEnabled: false,
    savedAppsSyncEnabled: false,
    hostedChatEnabled: false,
    aliasHost: process.env.ROACHNET_LOCAL_HOSTNAME || 'RoachNet',
    bridgeUrl: null,
    runtimeOrigin: null,
    linkedAt: null,
    lastSeenAt: null,
    lastUpdatedAt: null,
    notes: ['Native runtime is local-only unless the user arms online account metadata.'],
  }
}

function compactString(value, fallback = '', maxLength = 512) {
  const normalized = String(value ?? fallback)
    .replace(/\s+/g, ' ')
    .trim()
  return normalized.slice(0, maxLength)
}

function compactStringList(value, maxItems = 12) {
  const source = Array.isArray(value) ? value : String(value || '').split(',')
  return source
    .map((item) => compactString(item, '', 80))
    .filter(Boolean)
    .slice(0, maxItems)
}

function roachClawVaultPath(...parts) {
  return path.join(roachClawStateRoot, ...parts)
}

function legacyRoachClawVaultPath(...parts) {
  return path.join(legacyRoachClawStateRoot, ...parts)
}

function readRoachClawState(filename, fallback) {
  for (const target of [roachClawVaultPath(filename), legacyRoachClawVaultPath(filename)]) {
    try {
      if (existsSync(target)) {
        return JSON.parse(readFileSync(target, 'utf8'))
      }
    } catch {}
  }
  return fallback
}

function readRoachTailStateFile() {
  for (const target of [roachTailStatePath, legacyRoachTailStatePath]) {
    try {
      if (existsSync(target)) {
        return JSON.parse(readFileSync(target, 'utf8'))
      }
    } catch {}
  }
  return null
}

function writeRoachClawState(filename, state) {
  const target = roachClawVaultPath(filename)
  mkdirSync(path.dirname(target), { recursive: true })
  writeFileSync(target, JSON.stringify(state, null, 2))
  return state
}

function roachClawCollectionState(filename, collectionKey) {
  const state = readRoachClawState(filename, {
    schema: `org.roachnet.roachclaw.${collectionKey}.v1`,
    updatedAt: null,
    [collectionKey]: [],
  })
  if (!Array.isArray(state[collectionKey])) {
    state[collectionKey] = []
  }
  return state
}

function roachClawUpsertCollectionItem(filename, collectionKey, body, normalizeItem) {
  const state = roachClawCollectionState(filename, collectionKey)
  const now = new Date().toISOString()
  const id = compactString(body.id || `${collectionKey.slice(0, -1) || 'item'}_${randomUUID().replaceAll('-', '').slice(0, 16)}`, '', 80)
  const existingIndex = state[collectionKey].findIndex((item) => item.id === id)
  const existing = existingIndex >= 0 ? state[collectionKey][existingIndex] : {}
  const item = normalizeItem({ ...existing, ...body, id, updatedAt: now, createdAt: existing.createdAt || body.createdAt || now })
  if (existingIndex >= 0) {
    state[collectionKey][existingIndex] = item
  } else {
    state[collectionKey].unshift(item)
  }
  state.updatedAt = now
  return writeRoachClawState(filename, state)
}

function deleteRoachClawCollectionItem(filename, collectionKey, rawId) {
  const id = compactString(decodeURIComponent(String(rawId || '')), '', 120)
  if (!id) {
    throw new NativeApiRequestError('Item id is missing.', 400)
  }

  const state = roachClawCollectionState(filename, collectionKey)
  const before = state[collectionKey].length
  state[collectionKey] = state[collectionKey].filter((item) => item.id !== id)
  state.updatedAt = new Date().toISOString()
  writeRoachClawState(filename, state)
  return {
    success: true,
    ok: true,
    deleted: before !== state[collectionKey].length,
    id,
    state,
  }
}

function roachClawContactsState() {
  return roachClawCollectionState('contacts.json', 'contacts')
}

function upsertRoachClawContact(body) {
  return roachClawUpsertCollectionItem('contacts.json', 'contacts', body, (item) => ({
    id: item.id,
    name: compactString(item.name || item.displayName || item.email || item.handle || 'Unnamed contact', 'Unnamed contact', 120),
    handle: compactString(item.handle, '', 120) || null,
    email: compactString(item.email, '', 160) || null,
    relationship: compactString(item.relationship || item.role, '', 120) || null,
    tags: compactStringList(item.tags),
    notes: compactString(item.notes, '', 1000) || null,
    source: compactString(item.source || 'local', 'local', 80),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawTaskState() {
  return roachClawCollectionState('tasks.json', 'tasks')
}

function upsertRoachClawTask(body) {
  return roachClawUpsertCollectionItem('tasks.json', 'tasks', body, (item) => ({
    id: item.id,
    title: compactString(item.title || item.summary || 'Untitled task', 'Untitled task', 180),
    status: compactString(item.status || 'open', 'open', 40),
    priority: compactString(item.priority || 'normal', 'normal', 40),
    dueAt: compactString(item.dueAt || item.due || '', '', 80) || null,
    source: compactString(item.source || 'roachclaw', 'roachclaw', 80),
    notes: compactString(item.notes, '', 1000) || null,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawCalendarState() {
  return roachClawCollectionState('calendar.json', 'events')
}

function upsertRoachClawCalendarEvent(body) {
  return roachClawUpsertCollectionItem('calendar.json', 'events', body, (item) => ({
    id: item.id,
    title: compactString(item.title || 'Untitled event', 'Untitled event', 180),
    startAt: compactString(item.startAt || item.startsAt || item.start || '', '', 80) || null,
    endAt: compactString(item.endAt || item.endsAt || item.end || '', '', 80) || null,
    location: compactString(item.location, '', 180) || null,
    status: compactString(item.status || 'planned', 'planned', 40),
    source: compactString(item.source || 'roachclaw', 'roachclaw', 80),
    notes: compactString(item.notes, '', 1000) || null,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawReportsState() {
  return roachClawCollectionState('reports.json', 'reports')
}

function upsertRoachClawReport(body) {
  return roachClawUpsertCollectionItem('reports.json', 'reports', body, (item) => ({
    id: item.id,
    title: compactString(item.title || 'Untitled report', 'Untitled report', 180),
    kind: compactString(item.kind || 'research-brief', 'research-brief', 80),
    status: compactString(item.status || 'draft', 'draft', 40),
    summary: compactString(item.summary, '', 1200) || null,
    formats: compactStringList(item.formats || ['markdown']),
    vaultPath: compactString(item.vaultPath || item.path || '', '', 512) || null,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawMemoriesState() {
  return roachClawCollectionState('memories.json', 'memories')
}

function upsertRoachClawMemory(body) {
  return roachClawUpsertCollectionItem('memories.json', 'memories', body, (item) => ({
    id: item.id,
    title: compactString(item.title || item.summary || 'Memory', 'Memory', 160),
    content: compactString(item.content || item.body || item.text || '', '', 6000) || '',
    source: compactString(item.source || 'roachclaw', 'roachclaw', 120),
    importance: compactString(item.importance || 'normal', 'normal', 40),
    tags: compactStringList(item.tags),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawSkillsState() {
  return roachClawCollectionState('skills.json', 'skills')
}

function upsertRoachClawSkill(body) {
  return roachClawUpsertCollectionItem('skills.json', 'skills', body, (item) => ({
    id: item.id,
    name: compactString(item.name || item.title || 'RoachClaw skill', 'RoachClaw skill', 140),
    category: compactString(item.category || 'general', 'general', 80),
    description: compactString(item.description || item.summary || '', '', 1200) || null,
    body: compactString(item.body || item.instructions || item.procedure || '', '', 12000) || '',
    triggerHints: compactStringList(item.triggerHints || item.triggers || item.keywords),
    tags: compactStringList(item.tags),
    source: compactString(item.source || 'local', 'local', 80),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawEditorDraftsState() {
  return roachClawCollectionState('editor-drafts.json', 'drafts')
}

function upsertRoachClawEditorDraft(body) {
  return roachClawUpsertCollectionItem('editor-drafts.json', 'drafts', body, (item) => ({
    id: item.id,
    title: compactString(item.title || 'Untitled draft', 'Untitled draft', 180),
    format: compactString(item.format || 'markdown', 'markdown', 40),
    status: compactString(item.status || 'draft', 'draft', 40),
    target: compactString(item.target || item.path || '', '', 240) || null,
    body: compactString(item.body || item.content || '', '', 20000) || '',
    excerpt: compactString(item.excerpt || item.body || item.content || '', '', 500) || null,
    tags: compactStringList(item.tags),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawSearchCacheState() {
  return roachClawCollectionState('search-cache.json', 'entries')
}

function upsertRoachClawSearchCacheEntry(body) {
  return roachClawUpsertCollectionItem('search-cache.json', 'entries', body, (item) => ({
    id: item.id,
    query: compactString(item.query || item.title || 'Search query', 'Search query', 300),
    provider: compactString(item.provider || 'local', 'local', 80),
    summary: compactString(item.summary || item.answer || '', '', 4000) || null,
    status: compactString(item.status || 'cached', 'cached', 40),
    sourceCount: Number.isSafeInteger(Number(item.sourceCount)) ? Math.max(0, Number(item.sourceCount)) : compactStringList(item.sources).length,
    sources: compactStringList(item.sources, 20),
    tags: compactStringList(item.tags),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawGalleryState() {
  return roachClawCollectionState('gallery.json', 'assets')
}

function upsertRoachClawGalleryAsset(body) {
  return roachClawUpsertCollectionItem('gallery.json', 'assets', body, (item) => ({
    id: item.id,
    title: compactString(item.title || path.basename(String(item.path || 'Untitled asset')), 'Untitled asset', 180),
    kind: compactString(item.kind || 'image', 'image', 60),
    path: compactString(item.path || item.vaultPath || '', '', 512) || null,
    tags: compactStringList(item.tags),
    notes: compactString(item.notes, '', 1000) || null,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawWebhooksState() {
  return roachClawCollectionState('webhooks.json', 'webhooks')
}

function upsertRoachClawWebhook(body) {
  return roachClawUpsertCollectionItem('webhooks.json', 'webhooks', body, (item) => {
    const rawSecret = compactString(body.secret || body.signingSecret || '', '', 2000)
    const existingDigest = compactString(item.secretDigest || '', '', 160) || null
    return {
      id: item.id,
      name: compactString(item.name || item.label || 'Local webhook', 'Local webhook', 140),
      method: compactString(item.method || 'POST', 'POST', 12).toUpperCase(),
      path: compactString(item.path || `/api/roachclaw/hooks/${item.id}`, `/api/roachclaw/hooks/${item.id}`, 240),
      target: compactString(item.target || item.route || 'roachclaw', 'roachclaw', 160),
      scope: compactString(item.scope || 'local-integration', 'local-integration', 120),
      isActive: Boolean(item.isActive ?? item.enabled ?? true),
      secretDigest: rawSecret ? createHash('sha256').update(rawSecret).digest('hex') : existingDigest,
      secretHint: rawSecret ? `${rawSecret.slice(0, 2)}...${rawSecret.slice(-2)}` : (compactString(item.secretHint || '', '', 40) || null),
      tags: compactStringList(item.tags),
      createdAt: item.createdAt,
      updatedAt: item.updatedAt,
    }
  })
}

function roachClawAgentRunsState() {
  return roachClawCollectionState('agent-runs.json', 'runs')
}

function upsertRoachClawAgentRun(body) {
  return roachClawUpsertCollectionItem('agent-runs.json', 'runs', body, (item) => {
    const status = compactString(item.status || 'queued', 'queued', 40).toLowerCase()
    const events = Array.isArray(item.events) ? item.events : []
    return {
      id: item.id,
      sessionId: compactString(item.sessionId || item.session_id || 'local-session', 'local-session', 120),
      title: compactString(item.title || item.prompt || 'RoachClaw run', 'RoachClaw run', 180),
      status,
      model: compactString(item.model || defaultModel, defaultModel, 160),
      mode: compactString(item.mode || 'agent', 'agent', 60),
      promptPreview: compactString(item.promptPreview || item.prompt || '', '', 1000) || null,
      eventCount: Number.isSafeInteger(Number(item.eventCount)) ? Math.max(0, Number(item.eventCount)) : events.length,
      replayPreview: compactStringList(item.replayPreview || events, 12),
      lastEventAt: compactString(item.lastEventAt || item.updatedAt || '', '', 80) || item.updatedAt,
      createdAt: item.createdAt,
      updatedAt: item.updatedAt,
    }
  })
}

function roachClawContextCompactionsState() {
  return roachClawCollectionState('context-compactions.json', 'compactions')
}

function upsertRoachClawContextCompaction(body) {
  return roachClawUpsertCollectionItem('context-compactions.json', 'compactions', body, (item) => ({
    id: item.id,
    sessionId: compactString(item.sessionId || item.session_id || 'local-session', 'local-session', 120),
    title: compactString(item.title || 'Context compaction', 'Context compaction', 180),
    summary: compactString(item.summary || item.content || '', '', 8000) || '',
    turnsSummarized: Number.isSafeInteger(Number(item.turnsSummarized ?? item.turns)) ? Math.max(0, Number(item.turnsSummarized ?? item.turns)) : 0,
    tokensBefore: Number.isSafeInteger(Number(item.tokensBefore)) ? Math.max(0, Number(item.tokensBefore)) : null,
    tokensAfter: Number.isSafeInteger(Number(item.tokensAfter)) ? Math.max(0, Number(item.tokensAfter)) : null,
    contextWindow: Number.isSafeInteger(Number(item.contextWindow)) ? Math.max(0, Number(item.contextWindow)) : null,
    retentionPolicy: compactString(item.retentionPolicy || 'preserve-goals-decisions-paths', 'preserve-goals-decisions-paths', 120),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawToolIndexState() {
  return roachClawCollectionState('tool-index.json', 'tools')
}

function upsertRoachClawToolIndexEntry(body) {
  return roachClawUpsertCollectionItem('tool-index.json', 'tools', body, (item) => ({
    id: item.id,
    name: compactString(item.name || item.title || 'RoachClaw tool', 'RoachClaw tool', 140),
    kind: compactString(item.kind || item.type || 'native', 'native', 80),
    category: compactString(item.category || 'general', 'general', 80),
    description: compactString(item.description || item.summary || '', '', 1600) || null,
    invocation: compactString(item.invocation || item.command || item.route || '', '', 500) || null,
    enabled: Boolean(item.enabled ?? true),
    alwaysAvailable: Boolean(item.alwaysAvailable ?? item.always_available ?? false),
    tags: compactStringList(item.tags || item.keywords),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawEventsState() {
  return roachClawCollectionState('events.json', 'events')
}

function upsertRoachClawEvent(body) {
  return roachClawUpsertCollectionItem('events.json', 'events', body, (item) => {
    const increment = Number.isSafeInteger(Number(body.increment)) ? Math.max(0, Number(body.increment)) : 0
    const existingCount = Number.isSafeInteger(Number(item.count)) ? Math.max(0, Number(item.count)) : 0
    return {
      id: item.id,
      name: compactString(item.name || item.event || 'roachclaw.event', 'roachclaw.event', 140),
      owner: compactString(item.owner || 'local-owner', 'local-owner', 120),
      count: existingCount + increment,
      threshold: Number.isSafeInteger(Number(item.threshold)) ? Math.max(1, Number(item.threshold)) : 1,
      enabled: Boolean(item.enabled ?? true),
      lastFiredAt: compactString(item.lastFiredAt || item.firedAt || item.updatedAt || '', '', 80) || item.updatedAt,
      actions: compactStringList(item.actions || item.triggers, 12),
      createdAt: item.createdAt,
      updatedAt: item.updatedAt,
    }
  })
}

function roachClawMailState() {
  const state = readRoachClawState('mail.json', {
    schema: 'org.roachnet.roachclaw.mail.v1',
    updatedAt: null,
    accounts: [],
    messages: [],
    drafts: [],
  })
  for (const key of ['accounts', 'messages', 'drafts']) {
    if (!Array.isArray(state[key])) state[key] = []
  }
  return state
}

function writeRoachClawMailState(state) {
  state.updatedAt = new Date().toISOString()
  return writeRoachClawState('mail.json', state)
}

function upsertRoachClawMailMessage(body) {
  const state = roachClawMailState()
  const now = new Date().toISOString()
  const id = compactString(body.id || `message_${randomUUID().replaceAll('-', '').slice(0, 16)}`, '', 80)
  const existingIndex = state.messages.findIndex((item) => item.id === id)
  const existing = existingIndex >= 0 ? state.messages[existingIndex] : {}
  const message = {
    id,
    account: compactString(body.account || existing.account || 'local', 'local', 120),
    folder: compactString(body.folder || existing.folder || 'Inbox', 'Inbox', 120),
    from: compactString(body.from || existing.from || '', '', 180) || null,
    to: compactStringList(body.to || existing.to),
    subject: compactString(body.subject || existing.subject || 'Untitled message', 'Untitled message', 220),
    preview: compactString(body.preview || body.body || existing.preview || '', '', 1200) || null,
    tags: compactStringList(body.tags || existing.tags),
    read: Boolean(body.read ?? existing.read ?? false),
    receivedAt: compactString(body.receivedAt || existing.receivedAt || now, now, 80),
    createdAt: existing.createdAt || body.createdAt || now,
    updatedAt: now,
  }
  if (existingIndex >= 0) state.messages[existingIndex] = message
  else state.messages.unshift(message)
  return writeRoachClawMailState(state)
}

function upsertRoachClawMailDraft(body) {
  const state = roachClawMailState()
  const now = new Date().toISOString()
  const id = compactString(body.id || `draft_${randomUUID().replaceAll('-', '').slice(0, 16)}`, '', 80)
  const existingIndex = state.drafts.findIndex((item) => item.id === id)
  const existing = existingIndex >= 0 ? state.drafts[existingIndex] : {}
  const draft = {
    id,
    account: compactString(body.account || existing.account || 'local', 'local', 120),
    to: compactStringList(body.to || existing.to),
    cc: compactStringList(body.cc || existing.cc),
    subject: compactString(body.subject || existing.subject || 'Untitled draft', 'Untitled draft', 220),
    body: compactString(body.body || existing.body || '', '', 8000) || '',
    status: compactString(body.status || existing.status || 'draft', 'draft', 60),
    tags: compactStringList(body.tags || existing.tags),
    createdAt: existing.createdAt || body.createdAt || now,
    updatedAt: now,
  }
  if (existingIndex >= 0) state.drafts[existingIndex] = draft
  else state.drafts.unshift(draft)
  return writeRoachClawMailState(state)
}

function deleteRoachClawMailItem(collectionKey, rawId) {
  if (!['messages', 'drafts'].includes(collectionKey)) {
    throw new NativeApiRequestError('Unsupported RoachMail collection.', 400)
  }
  const id = compactString(decodeURIComponent(String(rawId || '')), '', 120)
  if (!id) throw new NativeApiRequestError('Mail item id is missing.', 400)
  const state = roachClawMailState()
  const before = state[collectionKey].length
  state[collectionKey] = state[collectionKey].filter((item) => item.id !== id)
  writeRoachClawMailState(state)
  return { success: true, ok: true, deleted: before !== state[collectionKey].length, id, state }
}

function roachClawPresetsState() {
  return roachClawCollectionState('presets.json', 'templates')
}

function upsertRoachClawPreset(body) {
  return roachClawUpsertCollectionItem('presets.json', 'templates', body, (item) => ({
    id: item.id,
    name: compactString(item.name || 'Untitled preset', 'Untitled preset', 120),
    systemPrompt: compactString(item.systemPrompt || item.system_prompt || '', '', 10000) || '',
    temperature: Number.isFinite(Number(item.temperature)) ? Math.min(2, Math.max(0, Number(item.temperature))) : 0.7,
    maxTokens: Number.isSafeInteger(Number(item.maxTokens ?? item.max_tokens)) ? Math.max(0, Number(item.maxTokens ?? item.max_tokens)) : 0,
    enabled: Boolean(item.enabled ?? true),
    tags: compactStringList(item.tags),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawSignaturesState() {
  return roachClawCollectionState('signatures.json', 'signatures')
}

function upsertRoachClawSignature(body) {
  return roachClawUpsertCollectionItem('signatures.json', 'signatures', body, (item) => ({
    id: item.id,
    name: compactString(item.name || 'Signature', 'Signature', 120),
    dataUrl: compactString(item.dataUrl || item.data_url || item.data || '', '', 500_000) || null,
    width: Number.isSafeInteger(Number(item.width)) ? Math.max(0, Number(item.width)) : null,
    height: Number.isSafeInteger(Number(item.height)) ? Math.max(0, Number(item.height)) : null,
    source: compactString(item.source || 'local', 'local', 80),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachClawApiTokensState() {
  return roachClawCollectionState('api-tokens.json', 'tokens')
}

function roachClawCloudProviderDefinitions() {
  return [
    {
      id: 'openai',
      name: 'OpenAI',
      envVar: 'OPENAI_API_KEY',
      baseUrl: 'https://api.openai.com/v1',
      scopes: ['chat', 'models', 'responses'],
      summary: 'Optional user-owned OpenAI route for cloud work the owner explicitly arms.',
    },
    {
      id: 'anthropic',
      name: 'Anthropic',
      envVar: 'ANTHROPIC_API_KEY',
      baseUrl: 'https://api.anthropic.com',
      scopes: ['chat', 'models'],
      summary: 'Optional Claude route for users who bring their own Anthropic key.',
    },
    {
      id: 'openrouter',
      name: 'OpenRouter',
      envVar: 'OPENROUTER_API_KEY',
      baseUrl: 'https://openrouter.ai/api/v1',
      scopes: ['chat', 'models', 'router'],
      summary: 'Optional user-owned router lane for models outside the local stack.',
    },
  ]
}

function normalizeRoachClawCloudProviderId(rawProvider) {
  const normalized = compactString(rawProvider, '', 80).toLowerCase().replace(/[^a-z0-9-]/g, '')
  const definition = roachClawCloudProviderDefinitions().find((provider) => provider.id === normalized)
  if (!definition) {
    throw new Error(`Unknown RoachClaw cloud provider: ${rawProvider || 'missing'}`)
  }
  return definition.id
}

function roachClawCloudProviderSecretPath(providerId) {
  return roachClawVaultPath('provider-secrets', `${providerId}.key`)
}

function legacyRoachClawCloudProviderSecretPath(providerId) {
  return legacyRoachClawVaultPath('provider-secrets', `${providerId}.key`)
}

function isRoachClawCloudProviderSecretDirectorySafe(secretDirectory, stateDirectory) {
  const root = path.parse(stateDirectory).root
  const ancestors = []
  for (let current = stateDirectory; current !== root; current = path.dirname(current)) {
    ancestors.push(current)
  }
  ancestors.push(root)
  for (const candidate of ancestors) {
    try {
      if (lstatSync(candidate).isSymbolicLink()) return false
    } catch {
      return false
    }
  }
  for (const candidate of [stateDirectory, secretDirectory]) {
    try {
      const stats = lstatSync(candidate)
      if (!stats.isDirectory() || stats.isSymbolicLink()) return false
    } catch {
      return false
    }
  }
  return true
}

function readRoachClawCloudProviderSecretFile(secretPath, source, stateDirectory) {
  let descriptor
  try {
    if (!isRoachClawCloudProviderSecretDirectorySafe(path.dirname(secretPath), stateDirectory)) return null
    const initial = lstatSync(secretPath)
    if (!initial.isFile() || initial.isSymbolicLink() || initial.size < 1 || initial.size > 8_192) return null
    descriptor = openSync(secretPath, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW)
    const opened = fstatSync(descriptor)
    if (!opened.isFile() || opened.size !== initial.size || opened.dev !== initial.dev || opened.ino !== initial.ino) return null
    const buffer = Buffer.allocUnsafe(opened.size)
    const bytesRead = readSync(descriptor, buffer, 0, buffer.length, 0)
    const completed = fstatSync(descriptor)
    if (bytesRead !== opened.size || completed.size !== opened.size || completed.dev !== opened.dev || completed.ino !== opened.ino) return null
    if (!isRoachClawCloudProviderSecretDirectorySafe(path.dirname(secretPath), stateDirectory)) return null
    const resolvedSecretPath = realpathSync(secretPath)
    const current = statSync(resolvedSecretPath)
    if (resolvedSecretPath !== secretPath || current.dev !== completed.dev || current.ino !== completed.ino) return null
    const value = buffer.toString('utf8', 0, bytesRead).trim()
    if (!value) return null
    return { source, value }
  } catch {
    return null
  } finally {
    if (descriptor !== undefined) closeSync(descriptor)
  }
}

function resolveRoachClawCloudProviderSecret(providerId) {
  for (const [secretPath, source, stateDirectory] of [
    [roachClawCloudProviderSecretPath(providerId), 'runtime-local-secret-file', roachClawStateRoot],
    [legacyRoachClawCloudProviderSecretPath(providerId), 'legacy-local-secret-file', legacyRoachClawStateRoot],
  ]) {
    const secret = readRoachClawCloudProviderSecretFile(secretPath, source, stateDirectory)
    if (secret) return secret
  }
  return null
}

function normalizePublicProviderBaseUrl(rawValue, fallback) {
  const value = compactString(rawValue || fallback, fallback, 240)
  let parsed
  try {
    parsed = new URL(value)
  } catch {
    throw new NativeApiRequestError('Cloud provider base URL must be a valid URL', 400)
  }
  if (!['https:', 'http:'].includes(parsed.protocol)) {
    throw new NativeApiRequestError('Cloud provider base URL must use HTTP or HTTPS', 400)
  }
  const host = parsed.hostname.toLowerCase()
  const literalIp = isIP(host)
  const blockedHostnames = ['localhost', 'localhost.localdomain']
  const blockedSuffixes = ['.local', '.lan', '.internal', '.home.arpa']
  if (
    blockedHostnames.includes(host) ||
    blockedSuffixes.some((suffix) => host.endsWith(suffix)) ||
    (literalIp === 4 && /^(10\.|127\.|169\.254\.|172\.(1[6-9]|2\d|3[0-1])\.|192\.168\.)/.test(host)) ||
    (literalIp === 6 && ['::1', 'fc', 'fd', 'fe80'].some((prefix) => host.startsWith(prefix)))
  ) {
    throw new NativeApiRequestError('Cloud provider base URL must be public; local/private targets belong in RoachNet local providers', 400)
  }
  parsed.hash = ''
  parsed.search = ''
  return parsed.toString().replace(/\/$/, '')
}

function roachClawCloudProviderKeysState() {
  const state = roachClawCollectionState('cloud-provider-keys.json', 'providers')
  state.schema = 'org.roachnet.roachclaw.cloud-provider-keys.v1'
  return state
}

function roachClawCloudProviderEnvMetadata(definition, now) {
  const rawKey = process.env[definition.envVar]?.trim()
  if (!rawKey) return null
  return {
    id: definition.id,
    provider: definition.id,
    name: definition.name,
    configured: true,
    configuredVia: 'environment',
    tokenPrefix: null,
    baseUrl: definition.baseUrl,
    scopes: definition.scopes,
    isActive: true,
    secretStorage: 'process-env',
    createdAt: now,
    updatedAt: now,
  }
}

function roachClawPublicCloudProviderKeysState() {
  const state = roachClawCloudProviderKeysState()
  const now = new Date().toISOString()
  const storedById = new Map(
    state.providers.map((provider) => [
      provider.provider || provider.id,
      {
        ...provider,
        configured: true,
        secretStorage: provider.secretStorage || 'local-0600-file',
      },
    ])
  )

  const providers = roachClawCloudProviderDefinitions().map((definition) => {
    const envProvider = roachClawCloudProviderEnvMetadata(definition, now)
    const stored = storedById.get(definition.id)
    const secret = resolveRoachClawCloudProviderSecret(definition.id)
    const configured = envProvider || (secret
      ? {
        ...stored,
        configured: true,
        configuredVia: secret.source,
        tokenPrefix: null,
        secretStorage: 'local-0600-file',
      }
      : null)
    return {
      id: definition.id,
      provider: definition.id,
      name: definition.name,
      summary: definition.summary,
      baseUrl: configured?.baseUrl || definition.baseUrl,
      scopes: configured?.scopes || definition.scopes,
      configured: Boolean(configured),
      configuredVia: configured?.configuredVia || 'none',
      tokenPrefix: configured?.tokenPrefix || null,
      isActive: Boolean(configured?.isActive ?? false),
      secretStorage: configured?.secretStorage || 'not-configured',
      envVar: definition.envVar,
      createdAt: configured?.createdAt || null,
      updatedAt: configured?.updatedAt || null,
    }
  })

  return {
    schema: state.schema,
    updatedAt: state.updatedAt,
    providers,
    count: providers.length,
    configured: providers.filter((provider) => provider.configured).length,
    active: providers.filter((provider) => provider.isActive).length,
    secretsPolicy: 'user-owned-provider-keys-stay-local-and-are-never-returned-by-api',
  }
}

function upsertRoachClawCloudProviderKey(body = {}) {
  const providerId = normalizeRoachClawCloudProviderId(body.provider || body.id)
  const definition = roachClawCloudProviderDefinitions().find((provider) => provider.id === providerId)
  const suppliedKey = String(body.key || body.apiKey || body.token || '')
  if (Buffer.byteLength(suppliedKey, 'utf8') > 8_192) {
    throw new Error(`${definition.name} API key exceeds the 8192-byte limit`)
  }
  const rawKey = suppliedKey.trim()
  if (!rawKey) {
    throw new Error(`Missing ${definition.name} API key`)
  }
  const now = new Date().toISOString()
  const state = roachClawCloudProviderKeysState()
  const secretPath = roachClawCloudProviderSecretPath(providerId)
  mkdirSync(path.dirname(secretPath), { recursive: true })
  writeFileSync(secretPath, rawKey, { mode: 0o600 })
  chmodSync(secretPath, 0o600)

  const record = {
    id: providerId,
    provider: providerId,
    name: definition.name,
    configuredVia: 'local-secret-file',
    tokenPrefix: null,
    keyHash: createHash('sha256').update(rawKey).digest('hex'),
    baseUrl: normalizePublicProviderBaseUrl(body.baseUrl || definition.baseUrl, definition.baseUrl),
    scopes: compactStringList(body.scopes || definition.scopes, 12),
    isActive: Boolean(body.isActive ?? true),
    secretStorage: 'local-0600-file',
    createdAt: state.providers.find((provider) => provider.provider === providerId || provider.id === providerId)?.createdAt || now,
    updatedAt: now,
  }
  const existingIndex = state.providers.findIndex((provider) => provider.provider === providerId || provider.id === providerId)
  if (existingIndex >= 0) state.providers.splice(existingIndex, 1, record)
  else state.providers.unshift(record)
  state.updatedAt = now
  writeRoachClawState('cloud-provider-keys.json', state)
  return {
    success: true,
    ok: true,
    provider: roachClawPublicCloudProviderKeysState().providers.find((provider) => provider.id === providerId),
    state: roachClawPublicCloudProviderKeysState(),
  }
}

function deleteRoachClawCloudProviderKey(rawProvider) {
  const providerId = normalizeRoachClawCloudProviderId(rawProvider)
  const state = roachClawCloudProviderKeysState()
  const before = state.providers.length
  state.providers = state.providers.filter((provider) => (provider.provider || provider.id) !== providerId)
  state.updatedAt = new Date().toISOString()
  writeRoachClawState('cloud-provider-keys.json', state)
  rmSync(roachClawCloudProviderSecretPath(providerId), { force: true })
  return {
    success: true,
    ok: true,
    deleted: before !== state.providers.length,
    provider: providerId,
    state: roachClawPublicCloudProviderKeysState(),
  }
}

function createRoachClawApiToken(body = {}) {
  const state = roachClawApiTokensState()
  const now = new Date().toISOString()
  const rawToken = `rn_${createHash('sha256').update(`${randomUUID()}:${now}:${compactString(body.name, '', 120)}`).digest('base64url').slice(0, 43)}`
  const token = {
    id: `token_${randomUUID().replaceAll('-', '').slice(0, 12)}`,
    name: compactString(body.name || 'RoachNet API token', 'RoachNet API token', 120),
    owner: compactString(body.owner || 'local-owner', 'local-owner', 120),
    tokenPrefix: null,
    tokenHash: createHash('sha256').update(rawToken).digest('hex'),
    scopes: compactStringList(body.scopes || ['chat']),
    isActive: Boolean(body.isActive ?? true),
    lastUsedAt: null,
    createdAt: now,
    updatedAt: now,
  }
  state.tokens.unshift(token)
  state.updatedAt = now
  writeRoachClawState('api-tokens.json', state)
  const { tokenHash, ...publicRecord } = token
  return {
    success: true,
    ok: true,
    token: rawToken,
    record: publicRecord,
    state: {
      ...state,
      tokens: state.tokens.map(({ tokenHash: _tokenHash, ...record }) => record),
    },
  }
}

function roachClawPublicApiTokensState() {
  const state = roachClawApiTokensState()
  return {
    ...state,
    tokens: state.tokens.map(({ tokenHash: _tokenHash, ...record }) => record),
  }
}

function deleteRoachClawApiToken(rawId) {
  const deleted = deleteRoachClawCollectionItem('api-tokens.json', 'tokens', rawId)
  return {
    ...deleted,
    state: roachClawPublicApiTokensState(),
  }
}

function roachClawBackupsState() {
  return roachClawCollectionState('backups.json', 'snapshots')
}

function roachClawWorkspaceBrowseRoot() {
  return normalizePath(process.env.ROACHNET_WORKSPACE_BROWSE_ROOT, os.homedir())
}

function browseRoachClawWorkspace(rawPath = '') {
  const fallbackRoot = roachClawWorkspaceBrowseRoot()
  const requested = normalizePath(rawPath, fallbackRoot)
  let resolved = fallbackRoot
  try {
    const candidate = realpathSync(requested)
    if (statSync(candidate).isDirectory()) {
      resolved = candidate
    }
  } catch {
    resolved = fallbackRoot
  }

  const dirs = readdirSync(resolved, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.'))
    .map((entry) => {
      const entryPath = path.join(resolved, entry.name)
      try {
        const stats = lstatSync(entryPath)
        if (stats.isSymbolicLink()) return null
        return {
          name: entry.name,
          path: entryPath,
          modifiedAt: statSync(entryPath).mtime.toISOString(),
        }
      } catch {
        return null
      }
    })
    .filter(Boolean)
    .sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: 'base' }))

  return {
    schema: 'org.roachnet.roachclaw.workspace-browser.v1',
    source: 'github-upstream-workspace-routes-native-rewrite',
    path: resolved,
    parent: path.dirname(resolved) === resolved ? null : path.dirname(resolved),
    dirs,
    count: dirs.length,
    policy: 'local-loopback-directories-only-hidden-and-symlinks-skipped',
  }
}

function roachClawMigrationDocumentToolsState() {
  const officeFormats = ['docx', 'doc', 'rtf', 'odt', 'pptx', 'xlsx']
  const documentLanguages = ['markdown', 'email', 'html', 'svg', 'json', 'python', 'javascript', 'typescript', 'sql', 'css']
  const migrationSources = ['ChatGPT exports', 'Claude projects', 'Codex sessions', 'memory JSON', 'markdown/text trees']
  const validators = ['remote_host:user@host-or-host-only', 'ssh_port:1-65535']
  const cookbookOutput = {
    completionMarkers: ['DOWNLOAD_OK', 'DOWNLOAD_FAILED'],
    errorTailLines: 50,
    runningTailLines: 12,
    zeroFileGuard: true,
    hfCacheProbe: 'complete-or-incomplete-marker-check',
  }

  return {
    schema: 'org.roachnet.roachclaw.migration-document-tools.v1',
    source: 'github-upstream-document-tools-native-rewrite',
    upstreamModules: [
      'src/agent_tools/document_tools.py',
      'src/office_doc.py',
      'src/optional_deps.py',
      'src/reminder_personas.py',
      'routes/_validators.py',
      'routes/cookbook_output.py',
      'scripts/agent_migration_manifest.py',
      'scripts/backfill_model_release_dates.py',
      'scripts/import_from_vllm_recipes.py',
      'static/js/cookbook-deps-recipes.js',
    ],
    status: 'native-state',
    storagePath: roachClawVaultPath('migration-document-tools.json'),
    count: 10,
    active: 6,
    route: 'roachnet://vault/document-tools',
    summaryItems: [
      'Office docs become vault docs',
      'agent imports preview first',
      'SSH targets validated',
      'cookbook logs explain failures',
    ],
    detail: 'Native document tools and migration previews for Office imports, active document context, portable agent manifests, cookbook output tails, optional dependency health, and safe remote-host validators.',
    actions: ['Import Office doc', 'Preview migration', 'Check optional deps', 'Classify cookbook output', 'Validate remote target'],
    documentTools: {
      activeDocument: 'vault-scoped',
      supportedFormats: officeFormats,
      languageSniffing: documentLanguages,
      blockParsers: ['edit blocks', 'suggestion blocks', 'code fences', 'markdown sections'],
      policy: 'documents are copied or converted into the local vault before RoachClaw touches them',
    },
    migrationManifest: {
      schema: 'agent-migration.v1-native-preview',
      sources: migrationSources,
      digest: 'sha256-stable-ids',
      dryRunDefault: true,
      secretsPolicy: 'manifest paths and digests only; raw secrets never exported',
    },
    cookbookOutput,
    optionalDependencies: {
      policy: 'native-capability-probes-not-python-import-shims',
      checked: ['Core ML model packs', 'RoachSpeech packs', 'vault converters', 'recipe caches'],
      fallback: 'show missing capability with install lane, never crash the shell',
    },
    reminderPersonas: [
      { id: 'socratic', label: 'Socratic', tone: 'questions first' },
      { id: 'razor', label: 'Razor', tone: 'sharp and brief' },
      { id: 'spark', label: 'Spark', tone: 'creative push' },
      { id: 'roach-strategist', label: 'Roach Strategist', tone: 'warm plan with receipts' },
    ],
    validators: {
      remoteHost: 'host-or-user-at-host-only-no-ssh-options',
      sshPort: '1-65535',
      targets: validators,
    },
  }
}

function roachClawUserTimeState() {
  const state = roachClawCollectionState('user-time.json', 'contexts')
  const record = state.contexts[0] || {}
  const timeZoneName = compactString(record.timeZoneName || Intl.DateTimeFormat().resolvedOptions().timeZone || 'local', 'local', 80)
  const offsetMinutes = Number.isFinite(Number(record.utcOffsetMinutes))
    ? Math.max(-840, Math.min(840, Number(record.utcOffsetMinutes)))
    : -new Date().getTimezoneOffset()
  const now = new Date()
  const utcOffset = formatRoachClawUtcOffset(offsetMinutes)
  return {
    schema: 'org.roachnet.roachclaw.user-time.v1',
    configured: Boolean(state.contexts[0]),
    timeZoneName,
    utcOffsetMinutes: offsetMinutes,
    utcOffset,
    localDateTime: now.toLocaleString('en-US', { timeZone: timeZoneName === 'local' ? undefined : timeZoneName }),
    promptContext: `User local time is ${now.toLocaleString('en-US', { timeZone: timeZoneName === 'local' ? undefined : timeZoneName })} (${timeZoneName}, UTC${utcOffset}).`,
    updatedAt: state.updatedAt,
  }
}

function formatRoachClawUtcOffset(minutes) {
  const sign = minutes >= 0 ? '+' : '-'
  const abs = Math.abs(minutes)
  return `${sign}${String(Math.floor(abs / 60)).padStart(2, '0')}:${String(abs % 60).padStart(2, '0')}`
}

function upsertRoachClawUserTime(body = {}) {
  const state = roachClawCollectionState('user-time.json', 'contexts')
  const now = new Date().toISOString()
  const offset = Number(body.utcOffsetMinutes ?? body.offsetMinutes)
  const record = {
    id: 'local-user-time',
    timeZoneName: compactString(body.timeZoneName || body.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone || 'local', 'local', 80),
    utcOffsetMinutes: Number.isFinite(offset) ? Math.max(-840, Math.min(840, Math.trunc(offset))) : -new Date().getTimezoneOffset(),
    source: compactString(body.source || 'native-settings', 'native-settings', 80),
    createdAt: state.contexts[0]?.createdAt || now,
    updatedAt: now,
  }
  state.contexts = [record]
  state.updatedAt = now
  writeRoachClawState('user-time.json', state)
  return roachClawUserTimeState()
}

function roachClawCookbookServeState() {
  const state = roachClawCollectionState('cookbook-serve-schedules.json', 'schedules')
  const now = Date.now()
  const schedules = state.schedules.map((schedule) => {
    const scheduledStopAtMs = Number(schedule.scheduledStopAtMs || 0)
    const active = Boolean(schedule.isActive) && (!scheduledStopAtMs || scheduledStopAtMs > now)
    return {
      ...schedule,
      active,
      expired: Boolean(schedule.isActive) && Boolean(scheduledStopAtMs) && scheduledStopAtMs <= now,
    }
  })
  return {
    schema: 'org.roachnet.roachclaw.cookbook-serve-schedules.v1',
    updatedAt: state.updatedAt,
    schedules,
    active: schedules.filter((schedule) => schedule.active).length,
    pending: schedules.filter((schedule) => String(schedule.status || '').toLowerCase() === 'scheduled').length,
    expired: schedules.filter((schedule) => schedule.expired).length,
    policy: 'local-scheduler-state-no-tmux-or-python-webui-required',
  }
}

function upsertRoachClawCookbookServeSchedule(body = {}) {
  const now = new Date().toISOString()
  const durationMinutes = Math.max(1, Math.min(24 * 60, Number(body.durationMinutes || 60)))
  const record = {
    id: compactString(body.id || `serve_${randomUUID().replaceAll('-', '').slice(0, 12)}`, '', 80),
    model: compactString(body.model || body.modelName || defaultModel, defaultModel, 160),
    repoId: compactString(body.repoId || body.repository || '', '', 180) || null,
    days: compactStringList(body.days || ['today'], 14),
    startTime: compactString(body.startTime || 'now', 'now', 20),
    endTime: compactString(body.endTime || '', '', 20) || null,
    durationMinutes,
    scheduledStopAtMs: Number(body.scheduledStopAtMs) || Date.now() + durationMinutes * 60_000,
    mirrorToCalendar: Boolean(body.mirrorToCalendar),
    status: compactString(body.status || 'scheduled', 'scheduled', 40),
    isActive: Boolean(body.isActive ?? true),
    createdAt: body.createdAt || now,
    updatedAt: now,
  }
  const state = roachClawCollectionState('cookbook-serve-schedules.json', 'schedules')
  const existingIndex = state.schedules.findIndex((schedule) => schedule.id === record.id)
  if (existingIndex >= 0) state.schedules.splice(existingIndex, 1, record)
  else state.schedules.unshift(record)
  state.updatedAt = now
  writeRoachClawState('cookbook-serve-schedules.json', state)
  return roachClawCookbookServeState()
}

function computeRoachClawCookbookProgressSignal(body = {}) {
  const bytes = Number(body.bytes || body.receivedBytes || 0)
  if (bytes > 0) return { schema: 'org.roachnet.roachclaw.progress-signal.v1', signal: `bytes:${bytes}`, mode: 'bytes' }
  const downloadAggregate = compactString(body.downloadAggregate || body.dlAgg || '', '', 120)
  const lastPercent = Number.isFinite(Number(body.lastPercent)) ? Math.max(0, Math.min(100, Number(body.lastPercent))) : 0
  const snapshotTail = compactString(body.snapshot || body.output || '', '', 4096).slice(-300)
  return {
    schema: 'org.roachnet.roachclaw.progress-signal.v1',
    signal: `${downloadAggregate || lastPercent}|${snapshotTail}`,
    mode: 'snapshot-tail',
  }
}

function roachClawScopedToolBridgeState() {
  const scopes = [
    'cookbook:read',
    'cookbook:launch',
    'todos:read',
    'todos:write',
    'memory:read',
    'memory:write',
    'calendar:read',
    'calendar:write',
    'documents:read',
    'documents:write',
    'documents:import',
    'email:read',
    'email:draft',
    'email:send',
    'diagnostics:read',
    'migration:read',
  ]
  const endpoints = [
    { id: 'capabilities', method: 'GET', path: '/api/roachclaw/scoped-tools/capabilities', scope: 'tools:read' },
    { id: 'operations', method: 'GET', path: '/api/roachclaw/operations', scope: 'operations:read' },
    { id: 'agent-run', method: 'POST', path: '/api/roachclaw/agent/run', scope: 'agent:run' },
    { id: 'memory-provider', method: 'GET', path: '/api/roachclaw/memory-provider', scope: 'memory:read' },
    { id: 'diagnostics-services', method: 'GET', path: '/api/roachclaw/diagnostics/services', scope: 'diagnostics:read' },
    { id: 'migration-document-tools', method: 'GET', path: '/api/roachclaw/migration-document-tools', scope: 'migration:read' },
  ]
  return {
    schema: 'org.roachnet.roachclaw.scoped-tool-bridge.v1',
    source: 'github-upstream-scoped-tool-routes-native-rewrite',
    localOnly: true,
    approvalRequired: true,
    scopes,
    endpoints,
    safety: ['loopback-native-api', 'owner-scoped-state', 'raw-secrets-redacted', 'action-approval-required'],
  }
}

function roachClawTlsOverridesState() {
  const state = roachClawCollectionState('tls-overrides.json', 'overrides')
  const record = state.overrides[0] || {}
  const bundlePath = compactString(record.bundlePath || process.env.LLM_CA_BUNDLE || '', '', 512)
  const valid = Boolean(bundlePath && existsSync(normalizePath(bundlePath, bundlePath)) && statSync(normalizePath(bundlePath, bundlePath)).isFile())
  return {
    schema: 'org.roachnet.roachclaw.tls-overrides.v1',
    configured: Boolean(bundlePath),
    valid,
    bundleLabel: bundlePath ? path.basename(bundlePath) : 'system trust',
    bundlePath: bundlePath ? '[local-path-redacted]' : null,
    scope: 'llm-provider-probes-only',
    verifyMode: 'default-plus-operator-ca-bundle',
    insecureDisableAllowed: false,
    updatedAt: state.updatedAt,
  }
}

function upsertRoachClawTlsOverride(body = {}) {
  const bundlePath = compactString(body.bundlePath || body.path || '', '', 512)
  if (!bundlePath) {
    writeRoachClawState('tls-overrides.json', { schema: 'org.roachnet.roachclaw.tls-overrides.v1', updatedAt: new Date().toISOString(), overrides: [] })
    return roachClawTlsOverridesState()
  }
  const resolvedPath = normalizePath(bundlePath, bundlePath)
  if (!existsSync(resolvedPath) || !statSync(resolvedPath).isFile()) {
    throw new NativeApiRequestError('TLS CA bundle path must point at a local PEM file', 400)
  }
  const now = new Date().toISOString()
  writeRoachClawState('tls-overrides.json', {
    schema: 'org.roachnet.roachclaw.tls-overrides.v1',
    updatedAt: now,
    overrides: [{
      id: 'llm-provider-ca-bundle',
      bundlePath: resolvedPath,
      scope: 'llm-provider-probes-only',
      verifyMode: 'default-plus-operator-ca-bundle',
      createdAt: now,
      updatedAt: now,
    }],
  })
  return roachClawTlsOverridesState()
}

function roachClawUploadLimitsState() {
  const limits = ROACHNET_UPLOAD_LIMIT_POLICIES.map((limit) => {
    const formatted = limit.bytes ? formatByteLimit(limit.bytes) : `${Math.round(limit.milliseconds / 1000)}s`
    return {
      ...limit,
      formatted,
      tunable: true,
      publicError: limit.bytes ? `${limit.label} exceeds ${formatted} limit.` : `${limit.label} exceeded ${formatted}.`,
    }
  })
  const laneCounts = limits.reduce((counts, limit) => {
    counts[limit.lane] = (counts[limit.lane] || 0) + 1
    return counts
  }, {})
  return {
    schema: 'org.roachnet.roachclaw.upload-limits.v1',
    source: 'github-upstream-upload-limits-native-rewrite',
    upstreamModule: 'src/upload_limits.py',
    policyVersion: '2026-06-08',
    limits,
    laneCounts,
    summaryItems: limits.map((limit) => `${limit.label}: ${limit.formatted}`),
    policy: 'centralized-hard-caps-public-413-clean-partial-files',
    envPrefix: 'ROACHNET_*',
    defaultPosture: 'bounded-local-intake-no-unlimited-uploads',
  }
}

function formatByteLimit(limit) {
  if (limit % (1024 * 1024 * 1024) === 0) return `${limit / (1024 * 1024 * 1024)} GB`
  if (limit % (1024 * 1024) === 0) return `${limit / (1024 * 1024)} MB`
  if (limit % 1024 === 0) return `${limit / 1024} KB`
  return `${limit} bytes`
}

function roachClawMemoryProviderState() {
  const state = roachClawCollectionState('memory-provider.json', 'providers')
  const configured = state.providers.length ? state.providers : []
  const nativeProvider = {
    id: 'roachbrain-native',
    providerId: 'native',
    displayName: 'RoachBrain native memory',
    enabled: true,
    storagePath: roachClawVaultPath('memories.json'),
    tools: ['remember', 'recall', 'list', 'delete'],
    localFirst: true,
  }
  return {
    schema: 'org.roachnet.roachclaw.memory-provider.v1',
    providers: [nativeProvider, ...configured.filter((provider) => provider.id !== nativeProvider.id)],
    policy: 'native-provider-always-available-external-providers-opt-in',
    updatedAt: state.updatedAt,
  }
}

function upsertRoachClawMemoryProvider(body = {}) {
  const provider = {
    id: compactString(body.id || body.providerId || `provider_${randomUUID().replaceAll('-', '').slice(0, 10)}`, '', 80),
    providerId: compactString(body.providerId || body.id || 'external', 'external', 80),
    displayName: compactString(body.displayName || body.name || 'External memory provider', 'External memory provider', 140),
    enabled: Boolean(body.enabled ?? false),
    localFirst: Boolean(body.localFirst ?? false),
    tools: compactStringList(body.tools || []),
    createdAt: body.createdAt || new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  }
  const state = roachClawCollectionState('memory-provider.json', 'providers')
  state.providers = state.providers.filter((item) => item.id !== provider.id)
  if (provider.id !== 'roachbrain-native') state.providers.unshift(provider)
  state.updatedAt = provider.updatedAt
  writeRoachClawState('memory-provider.json', state)
  return roachClawMemoryProviderState()
}

function roachClawProviderOAuthState() {
  const state = roachClawCollectionState('provider-oauth.json', 'flows')
  return {
    schema: 'org.roachnet.roachclaw.provider-oauth.v1',
    redirectBase: 'roachnet://provider-oauth/callback',
    authWaitSeconds: 300,
    flows: state.flows.map(({ token, refreshToken, accessToken, ...flow }) => flow),
    policy: 'user-owned-remote-tools-only-token-material-never-exported',
    updatedAt: state.updatedAt,
  }
}

function upsertRoachClawProviderOAuthFlow(body = {}) {
  const now = new Date().toISOString()
  const flow = {
    id: compactString(body.id || `oauth_${randomUUID().replaceAll('-', '').slice(0, 12)}`, '', 80),
    provider: compactString(body.provider || 'mcp-server', 'mcp-server', 120),
    serverUrl: body.serverUrl ? normalizePublicProviderBaseUrl(body.serverUrl, body.serverUrl) : null,
    scopes: compactStringList(body.scopes || []),
    status: compactString(body.status || 'needs-user-authorization', 'needs-user-authorization', 80),
    needsUserAction: Boolean(body.needsUserAction ?? true),
    isActive: Boolean(body.isActive ?? false),
    authUrl: body.authUrl ? '[redacted-user-auth-url]' : null,
    createdAt: body.createdAt || now,
    updatedAt: now,
  }
  const state = roachClawCollectionState('provider-oauth.json', 'flows')
  const existingIndex = state.flows.findIndex((item) => item.id === flow.id)
  if (existingIndex >= 0) state.flows.splice(existingIndex, 1, flow)
  else state.flows.unshift(flow)
  state.updatedAt = now
  writeRoachClawState('provider-oauth.json', state)
  return roachClawProviderOAuthState()
}

function roachClawEmbeddingFingerprint(laneName, endpoint, model, dimension) {
  return createHash('sha256')
    .update(`${laneName}\n${endpoint}\n${model}\n${dimension || 0}`)
    .digest('hex')
    .slice(0, 16)
}

function sanitizeEmbeddingEndpoint(rawValue) {
  const raw = compactString(rawValue, '', 512)
  if (!raw) return ''
  try {
    const parsed = new URL(raw)
    if (!['http:', 'https:', 'file:', 'local:'].includes(parsed.protocol)) {
      return ''
    }
    parsed.username = ''
    parsed.password = ''
    parsed.search = ''
    parsed.hash = ''
    return parsed.toString().replace(/\/$/, '')
  } catch {
    return raw.startsWith('local://') ? raw : ''
  }
}

function roachClawEmbeddingLanesState() {
  const state = roachClawCollectionState('embedding-lanes.json', 'lanes')
  const memories = roachClawMemoriesState()
  const skills = roachClawSkillsState()
  const searchCache = roachClawSearchCacheState()
  const toolIndex = roachClawToolIndexState()
  const localDimension = Math.max(1, Math.trunc(Number(process.env.ROACHNET_LOCAL_EMBEDDING_DIMENSION || 384)))
  const localModel = compactString(process.env.ROACHNET_LOCAL_EMBEDDING_MODEL || 'roachbrain-native-local-embeddings', 'roachbrain-native-local-embeddings', 160)
  const localEndpoint = 'local://roachbrain'
  const localIndexedCount =
    memories.memories.length + skills.skills.length + searchCache.entries.length + toolIndex.tools.length
  const configuredCustom = state.lanes.find((lane) => lane.id === 'custom' || lane.name === 'custom') || {}
  const customEndpoint = sanitizeEmbeddingEndpoint(
    configuredCustom.endpointUrl || configuredCustom.url || process.env.ROACHNET_CUSTOM_EMBEDDING_URL || process.env.EMBEDDING_URL || ''
  )
  const customModel = compactString(
    configuredCustom.model || process.env.ROACHNET_CUSTOM_EMBEDDING_MODEL || process.env.EMBEDDING_MODEL || '',
    '',
    160
  )
  const customDimension = Number(configuredCustom.dimension || process.env.ROACHNET_CUSTOM_EMBEDDING_DIMENSION || 0)
  const customEnabled = Boolean(configuredCustom.enabled ?? Boolean(customEndpoint || customModel || customDimension))
  const customHealthy = Boolean(customEnabled && customEndpoint && customModel && Number.isSafeInteger(customDimension) && customDimension > 0)
  const customFingerprint = customHealthy
    ? roachClawEmbeddingFingerprint('custom', customEndpoint, customModel, customDimension)
    : null
  const customLane = {
    id: 'custom',
    name: 'custom',
    label: 'Custom',
    kind: 'custom',
    enabled: customEnabled,
    collectionName: 'roachbrain_custom',
    model: customModel || null,
    endpoint: customEndpoint ? '[user-owned-endpoint-redacted]' : null,
    endpointLabel: customEndpoint ? endpointDisplayLabel(customEndpoint) : null,
    dimension: customHealthy ? customDimension : null,
    fingerprint: customFingerprint,
    indexedCount: 0,
    health: {
      status: customHealthy ? 'healthy' : (customEnabled ? 'needs-configuration' : 'not-configured'),
      healthy: customHealthy,
      reason: customHealthy
        ? 'custom embedding lane metadata is complete'
        : 'custom lane needs endpoint, model, and dimension before it can be promoted',
    },
    resetSafety: {
      destructiveResetAllowed: false,
      preservePreviousLane: true,
      requiresReindexBeforePromotion: true,
      resetReasons: ['dimension-change', 'model-change', 'fingerprint-change'],
      lastResetAt: state.lastResetAt || null,
    },
  }
  const localLane = {
    id: 'local',
    name: 'local',
    label: 'Local',
    kind: 'local',
    enabled: true,
    collectionName: 'roachbrain_local',
    model: localModel,
    endpoint: localEndpoint,
    endpointLabel: 'RoachBrain local',
    dimension: localDimension,
    fingerprint: roachClawEmbeddingFingerprint('local', localEndpoint, localModel, localDimension),
    indexedCount: localIndexedCount,
    health: {
      status: 'healthy',
      healthy: true,
      reason: 'native local lane is always available without Chroma, Flask, or WebUI coupling',
    },
    resetSafety: {
      destructiveResetAllowed: false,
      preservePreviousLane: true,
      requiresReindexBeforePromotion: false,
      resetReasons: ['native-index-rebuild'],
      lastResetAt: state.lastResetAt || null,
    },
  }
  const lanes = [customLane, localLane]
  const active = lanes.filter((lane) => lane.enabled)
  const healthy = active.filter((lane) => lane.health.healthy)

  return {
    schema: 'org.roachnet.roachbrain.embedding-lanes.v1',
    source: 'github-upstream-embedding-lanes-native-rewrite',
    updatedAt: state.updatedAt,
    localFirst: true,
    pythonRuntimeDependency: 'none',
    storagePath: roachClawVaultPath('embedding-lanes.json'),
    preferredOrder: ['custom', 'local'],
    lanes,
    stats: {
      laneCount: lanes.length,
      activeLaneCount: active.length,
      healthyLaneCount: healthy.length,
      totalIndexedRecords: localIndexedCount,
      memories: memories.memories.length,
      skills: skills.skills.length,
      searchCache: searchCache.entries.length,
      tools: toolIndex.tools.length,
    },
    resetSafety: {
      destructiveResetAllowed: false,
      resetEndpoint: '/api/roachclaw/embedding-lanes',
      policy: 'metadata-first-reset-preserves-old-lane-until-reindex-succeeds',
      lastResetAt: state.lastResetAt || null,
    },
    health: {
      status: healthy.length > 0 ? 'healthy' : 'needs-attention',
      healthy: healthy.length > 0,
      warnings: customEnabled && !customHealthy ? ['Custom embedding lane is incomplete and will not be promoted.'] : [],
    },
  }
}

function endpointDisplayLabel(rawEndpoint) {
  try {
    const parsed = new URL(rawEndpoint)
    if (parsed.protocol === 'local:') return rawEndpoint
    const pathLabel = parsed.pathname && parsed.pathname !== '/' ? parsed.pathname : ''
    return `${parsed.protocol}//${parsed.host}${pathLabel}`
  } catch {
    return compactString(rawEndpoint, '', 160)
  }
}

function upsertRoachClawEmbeddingLane(body = {}) {
  const now = new Date().toISOString()
  const state = roachClawCollectionState('embedding-lanes.json', 'lanes')
  if (body.reset === true || body.resetRequested === true) {
    state.lastResetAt = now
  }
  const laneId = compactString(body.id || body.name || body.lane || 'custom', 'custom', 80)
  if (laneId !== 'custom') {
    throw new NativeApiRequestError('Only the custom embedding lane is configurable from the native API.', 400)
  }
  const dimension = Number(body.dimension || body.dimensions || 0)
  const lane = {
    id: 'custom',
    name: 'custom',
    endpointUrl: sanitizeEmbeddingEndpoint(body.endpointUrl || body.url || body.endpoint || ''),
    model: compactString(body.model || '', '', 160),
    dimension: Number.isSafeInteger(dimension) && dimension > 0 ? dimension : null,
    enabled: Boolean(body.enabled ?? true),
    createdAt: state.lanes.find((item) => item.id === 'custom')?.createdAt || now,
    updatedAt: now,
  }
  state.lanes = [lane, ...state.lanes.filter((item) => item.id !== 'custom' && item.name !== 'custom')]
  state.updatedAt = now
  writeRoachClawState('embedding-lanes.json', state)
  return roachClawEmbeddingLanesState()
}

const ROACHCLAW_COMMON_TOOL_NAMES = [
  'api_call',
  'app_api',
  'archive_email',
  'ask_teacher',
  'ask_user',
  'bash',
  'builtin_browser',
  'chat_with_model',
  'create_document',
  'create_session',
  'delete_email',
  'download_model',
  'edit_document',
  'edit_file',
  'generate_image',
  'glob',
  'grep',
  'list_models',
  'ls',
  'manage_calendar',
  'manage_contact',
  'manage_documents',
  'manage_mcp',
  'manage_memory',
  'manage_notes',
  'manage_session',
  'manage_settings',
  'manage_tasks',
  'python',
  'read_file',
  'search_chats',
  'send_email',
  'ui_control',
  'update_plan',
  'vault_get',
  'vault_search',
  'web_fetch',
  'web_search',
  'write_file',
]

const ROACHCLAW_GUIDE_ONLY_PATTERNS = [
  [/\bguide[-\s]?only mode\b/i, 'guide-only mode requested'],
  [/\bno[-\s]?tools? mode\b/i, 'no-tools mode requested'],
  [/\bdo not use (?:any )?tools?\b/i, 'user forbade tool use'],
  [/\bdon'?t use (?:any )?tools?\b/i, 'user forbade tool use'],
  [/\bnot allowed to use (?:any )?tools?\b/i, 'user forbade tool use'],
  [/\bnot allowed to:?.{0,120}\buse (?:any )?tools?\b/i, 'user forbade tool use'],
  [/\bask (?:me )?(?:for confirmation )?before using tools?\b/i, 'user requested confirmation before tools'],
]

function detectRoachClawGuideOnlyTurn(message) {
  const text = compactString(message, '', 20_000)
  if (!text) return null
  const normalized = text.replace(/\s+/g, ' ')
  for (const [pattern, reason] of ROACHCLAW_GUIDE_ONLY_PATTERNS) {
    if (pattern.test(normalized)) return reason
  }
  return null
}

function roachClawKnownToolNames() {
  const names = new Set(ROACHCLAW_COMMON_TOOL_NAMES)
  for (const tool of roachClawToolIndexState().tools) {
    const name = compactString(tool.name || tool.id, '', 120)
    if (name) names.add(name)
  }
  for (const endpoint of roachClawScopedToolBridgeState().endpoints) {
    if (endpoint.id) names.add(endpoint.id)
  }
  return [...names].sort((left, right) => left.localeCompare(right))
}

function roachClawToolPolicyState(input = {}) {
  const state = roachClawCollectionState('tool-policy.json', 'disabledTools')
  const requestedDisabled = compactStringList(input.disabledTools || input.disabled || [], 200)
  const persistedDisabled = compactStringList(state.disabledTools || [], 200)
  const knownTools = roachClawKnownToolNames()
  const knownSet = new Set(knownTools)
  const disabled = new Set([...persistedDisabled, ...requestedDisabled].filter(Boolean))
  const hidden = new Set()
  const reasons = {}
  for (const tool of disabled) {
    reasons[tool] = 'Tool is disabled for this request.'
  }
  const guideReason = detectRoachClawGuideOnlyTurn(input.lastUserMessage || input.message || '')
  if (guideReason) {
    for (const tool of knownTools) {
      disabled.add(tool)
      hidden.add(tool)
      reasons[tool] = `${guideReason}.`
    }
  }
  const disabledTools = [...disabled].sort((left, right) => left.localeCompare(right))
  const hiddenTools = [...hidden].sort((left, right) => left.localeCompare(right))
  const mode = guideReason ? 'guide_only' : 'normal'
  return {
    schema: 'org.roachnet.roachclaw.tool-policy.v1',
    source: 'github-upstream-tool-policy-native-rewrite',
    mode,
    guideOnlyDetected: Boolean(guideReason),
    guideOnlyReason: guideReason,
    blockAllToolCalls: Boolean(guideReason),
    disableMcp: Boolean(guideReason),
    knownToolCount: knownSet.size,
    disabledCount: disabledTools.length,
    hiddenCount: hiddenTools.length,
    disabledTools,
    hiddenTools,
    reasons,
    enforcement: {
      promptDirectiveInjected: Boolean(guideReason),
      functionSchemasHidden: Boolean(guideReason),
      mcpDiscoveryDisabled: Boolean(guideReason),
      executorBackstop: true,
      nativeDisplayReady: true,
    },
    display: {
      statusLabel: guideReason ? 'Guide Only' : 'Tools Allowed',
      summaryItems: [
        guideReason ? 'guide-only' : 'normal',
        `${disabledTools.length} disabled`,
        `${hiddenTools.length} hidden`,
      ],
    },
    updatedAt: state.updatedAt,
  }
}

function upsertRoachClawToolPolicy(body = {}) {
  const state = roachClawCollectionState('tool-policy.json', 'disabledTools')
  state.disabledTools = compactStringList(body.disabledTools || body.disabled || [], 200)
  state.updatedAt = new Date().toISOString()
  writeRoachClawState('tool-policy.json', state)
  return roachClawToolPolicyState(body)
}

function roachClawReadinessState() {
  const checks = {}
  const checkWritableDirectory = (id, targetPath) => {
    try {
      mkdirSync(targetPath, { recursive: true })
      const probePath = path.join(targetPath, `.roachnet-ready-${randomUUID()}`)
      writeFileSync(probePath, 'ok')
      rmSync(probePath, { force: true })
      checks[id] = { ok: true, path: targetPath }
    } catch (error) {
      checks[id] = { ok: false, path: targetPath, error: error.message }
    }
  }

  checkWritableDirectory('storageRoot', storageRoot)
  checkWritableDirectory('runtimeStateRoot', runtimeStateRoot)
  checkWritableDirectory('vaultRoot', path.join(storageRoot, 'Vault'))
  const localFirst = !/^https?:\/\//i.test(storageRoot) && path.isAbsolute(storageRoot)
  checks.localFirst = { ok: true, local: localFirst }
  const ready = Object.values(checks).every((check) => Boolean(check.ok))
  return {
    schema: 'org.roachnet.roachclaw.readiness.v1',
    source: 'github-upstream-readiness-native-rewrite',
    ready,
    localFirst,
    version: packageJson.version,
    checks,
    timestamp: new Date().toISOString(),
  }
}

function roachClawContextBudgetState() {
  const state = roachClawCollectionState('context-budget.json', 'profiles')
  const profile = state.profiles[0] || {}
  return computeRoachClawContextBudget(profile)
}

function computeRoachClawContextBudget(body = {}) {
  const configured = Math.max(0, Math.trunc(Number(body.configuredBudget ?? body.configured ?? 6000)))
  const modelContextLength = Math.max(0, Math.trunc(Number(body.modelContextLength ?? body.contextLength ?? 0)))
  const explicit = Boolean(body.explicit)
  const headroom = Math.max(0.1, Math.min(0.95, Number(body.headroom ?? 0.85)))
  const hardMax = Math.max(1024, Math.min(1_000_000, Math.trunc(Number(body.hardMax ?? 200_000))))
  let effectiveBudget = configured || 6000
  if (explicit && configured > 0) effectiveBudget = modelContextLength > 0 ? Math.min(configured, modelContextLength) : configured
  else if (modelContextLength > 0) effectiveBudget = Math.max(1, Math.min(Math.trunc(modelContextLength * headroom), hardMax))
  return {
    schema: 'org.roachnet.roachclaw.context-budget.v1',
    source: 'github-upstream-context-budget-native-rewrite',
    configuredBudget: configured || 6000,
    modelContextLength,
    explicit,
    headroom,
    headroomPercent: Math.round(headroom * 100),
    hardMax,
    effectiveBudget,
    updatedAt: body.updatedAt || new Date().toISOString(),
  }
}

function upsertRoachClawContextBudget(body = {}) {
  const now = new Date().toISOString()
  const record = {
    id: 'default-context-budget',
    configuredBudget: Math.max(0, Math.trunc(Number(body.configuredBudget ?? body.configured ?? 6000))),
    modelContextLength: Math.max(0, Math.trunc(Number(body.modelContextLength ?? body.contextLength ?? 0))),
    explicit: Boolean(body.explicit),
    headroom: Math.max(0.1, Math.min(0.95, Number(body.headroom ?? 0.85))),
    hardMax: Math.max(1024, Math.min(1_000_000, Math.trunc(Number(body.hardMax ?? 200_000)))),
    createdAt: body.createdAt || now,
    updatedAt: now,
  }
  const state = roachClawCollectionState('context-budget.json', 'profiles')
  state.profiles = [record]
  state.updatedAt = now
  writeRoachClawState('context-budget.json', state)
  return computeRoachClawContextBudget(record)
}

function roachClawRequestContracts() {
  return {
    schema: 'org.roachnet.roachclaw.request-contracts.v1',
    source: 'github-upstream-request-models-native-rewrite',
    chat: {
      message: { minLength: 1, maxLength: 50_000 },
      attachments: { maxItems: 24 },
      timeFilters: ['day', 'week', 'month', 'year'],
      flags: ['useWeb', 'useResearch', 'presetId'],
    },
    memory: {
      text: { minLength: 1, maxLength: 5_000 },
      categories: ['fact', 'contact', 'task', 'preference', 'identity', 'project', 'goal'],
    },
    preset: {
      nameMaxLength: 50,
      systemPromptMaxLength: 10_000,
      injectTextMaxLength: 5_000,
      temperature: { min: 0, max: 2 },
      maxTokens: { min: 0, max: 8192 },
    },
    directory: {
      pathMaxLength: 500,
      policy: 'directory requests route through the native workspace browser',
    },
  }
}

async function checkRoachClawOutboundUrl(rawUrl, { blockPrivate = false } = {}) {
  if (typeof rawUrl !== 'string' || !rawUrl.trim()) {
    return { ok: false, reason: 'URL is required' }
  }
  let parsed
  try {
    parsed = new URL(rawUrl.trim())
  } catch (error) {
    return { ok: false, reason: `unparseable URL: ${error.message}` }
  }
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    return { ok: false, reason: `scheme must be http or https, got '${parsed.protocol.replace(':', '') || '(none)'}'` }
  }
  const host = parsed.hostname
  if (!host) return { ok: false, reason: 'URL has no host' }
  const rawAddresses = isIP(host)
    ? [{ address: host }]
    : await lookup(host, { all: true }).catch((error) => [{ error: error.message }])
  if (!rawAddresses.length || rawAddresses[0]?.error) {
    return { ok: false, reason: `host does not resolve${rawAddresses[0]?.error ? `: ${rawAddresses[0].error}` : ''}` }
  }
  for (const entry of rawAddresses) {
    const reason = classifyRoachClawOutboundAddress(entry.address, blockPrivate)
    if (reason) return { ok: false, reason }
  }
  return { ok: true, reason: 'ok' }
}

function classifyRoachClawOutboundAddress(address, blockPrivate = false) {
  const host = String(address || '').toLowerCase()
  if (!host) return 'empty address'
  if (/^169\.254\./.test(host) || host.startsWith('fe80:')) return `link-local address blocked (SSRF metadata risk): ${host}`
  if (/^(0\.|224\.|239\.)/.test(host) || host === '::' || host.startsWith('ff')) return `disallowed address: ${host}`
  if (blockPrivate && (host === 'localhost' || host === '::1' || /^(10\.|127\.|172\.(1[6-9]|2\d|3[0-1])\.|192\.168\.)/.test(host) || host.startsWith('fc') || host.startsWith('fd'))) {
    return `private/loopback address blocked: ${host}`
  }
  return null
}

function roachClawExportPayload() {
  return {
    schema: 'org.roachnet.roachclaw.export.v1',
    exportedAt: new Date().toISOString(),
    contacts: roachClawContactsState().contacts,
    tasks: roachClawTaskState().tasks,
    calendar: roachClawCalendarState().events,
    reports: roachClawReportsState().reports,
    memories: roachClawMemoriesState().memories,
    skills: roachClawSkillsState().skills,
    editorDrafts: roachClawEditorDraftsState().drafts,
    searchCache: roachClawSearchCacheState().entries,
    gallery: roachClawGalleryState().assets,
    webhooks: roachClawWebhooksState().webhooks,
    agentRuns: roachClawAgentRunsState().runs,
    contextCompactions: roachClawContextCompactionsState().compactions,
    toolIndex: roachClawToolIndexState().tools,
    events: roachClawEventsState().events,
    mail: roachClawMailState(),
    presets: roachClawPresetsState().templates,
    signatures: roachClawSignaturesState().signatures.map((signature) => ({
      ...signature,
      dataUrl: signature.dataUrl ? '[redacted-export-signature-payload]' : null,
    })),
    apiTokens: roachClawPublicApiTokensState().tokens,
    cloudProviders: roachClawPublicCloudProviderKeysState().providers,
    userTime: roachClawUserTimeState(),
    cookbookServeSchedules: roachClawCookbookServeState().schedules,
    contextBudget: roachClawContextBudgetState(),
    readiness: roachClawReadinessState(),
    scopedToolBridge: roachClawScopedToolBridgeState(),
    tlsOverrides: roachClawTlsOverridesState(),
    uploadLimits: roachClawUploadLimitsState(),
    memoryProvider: roachClawMemoryProviderState(),
    providerOAuth: roachClawProviderOAuthState(),
    embeddingLanes: roachClawEmbeddingLanesState(),
    toolPolicy: roachClawToolPolicyState(),
  }
}

function createRoachClawBackup(body = {}) {
  const exportPayload = roachClawExportPayload()
  const snapshot = upsertRoachClawBackupSnapshot({
    title: body.title || `RoachClaw backup ${new Date().toISOString()}`,
    sections: Object.keys(exportPayload).filter((key) => Array.isArray(exportPayload[key]) || typeof exportPayload[key] === 'object'),
    summary: `Contacts ${exportPayload.contacts.length}, tasks ${exportPayload.tasks.length}, events ${exportPayload.calendar.length}, reports ${exportPayload.reports.length}.`,
  })
  return {
    success: true,
    ok: true,
    export: exportPayload,
    snapshots: snapshot,
  }
}

function upsertRoachClawBackupSnapshot(body) {
  return roachClawUpsertCollectionItem('backups.json', 'snapshots', body, (item) => ({
    id: item.id,
    title: compactString(item.title || 'RoachClaw backup', 'RoachClaw backup', 180),
    summary: compactString(item.summary || '', '', 600) || null,
    sections: compactStringList(item.sections || []),
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
  }))
}

function roachTailDeviceId() {
  return createHash('sha256')
    .update(`${os.hostname()}::${storageRoot}`)
    .digest('hex')
    .slice(0, 16)
}

function roachTailNetworkName() {
  return process.env.ROACHTAIL_NETWORK_NAME?.trim() || 'RoachTail'
}

function roachTailNamespace() {
  return process.env.ROACHTAIL_NAMESPACE?.trim() || 'roachnet'
}

function roachTailNow() {
  return new Date().toISOString()
}

function roachTailHash(value) {
  return createHash('sha256').update(String(value || '')).digest('hex')
}

function generateRoachTailJoinCode() {
  return randomUUID()
    .replaceAll('-', '')
    .slice(0, 12)
    .toUpperCase()
    .match(/.{1,4}/g)
    .join('-')
}

function generateRoachTailSecret(prefix) {
  return `${prefix}_${randomUUID().replaceAll('-', '')}${randomUUID().replaceAll('-', '')}`
}

function roachTailAddMs(ms) {
  return new Date(Date.now() + ms).toISOString()
}

function roachTailBridgeUrl() {
  return process.env.ROACHNET_COMPANION_ADVERTISED_URL?.trim() || companionLocalUrl()
}

function roachTailRuntimeOrigin() {
  const host = process.env.HOST?.trim() || '127.0.0.1'
  const displayHost = host === '0.0.0.0' || host === '::' ? '127.0.0.1' : host
  const port = process.env.PORT?.trim() || '8080'
  return `http://${displayHost.includes(':') ? `[${displayHost}]` : displayHost}:${port}`
}

function normalizeRoachTailRelayHost(value) {
  const trimmed = String(value || '').trim()
  if (!trimmed) return null
  try {
    const parsed = new URL(trimmed.includes('://') ? trimmed : `https://${trimmed}`)
    if (!['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname) return null
    return parsed.host
  } catch {
    return null
  }
}

function roachTailAdvertisedUrl(relayHost, fallbackUrl = roachTailBridgeUrl()) {
  const normalizedRelay = normalizeRoachTailRelayHost(relayHost)
  if (!normalizedRelay) return fallbackUrl || null
  return `https://${normalizedRelay}`
}

function roachTailRuntimeTunnelUrl(relayHost, fallbackUrl = roachTailRuntimeOrigin()) {
  const normalizedRelay = normalizeRoachTailRelayHost(relayHost)
  if (!normalizedRelay) return fallbackUrl || null
  return `https://${normalizedRelay}/runtime`
}

function roachTailStatusFor(state) {
  if (!state.enabled) return 'local-only'
  if (state.peers?.some((peer) => peer.status === 'connected')) return 'connected'
  return state.relayHost ? 'relay-ready' : 'armed'
}

function roachTailTransportModeFor(state) {
  if (!state.enabled) return 'local-only'
  return state.relayHost ? 'tailnet-relay' : 'local-bridge'
}

function createRoachTailPreAuthKey(joinCode, issuedAt = roachTailNow()) {
  return {
    id: `rtpak_${randomUUID().replaceAll('-', '').slice(0, 16)}`,
    keyHash: roachTailHash(joinCode),
    createdAt: issuedAt,
    expiresAt: roachTailAddMs(ROACHTAIL_JOIN_CODE_TTL_MS),
    reusable: false,
    ephemeral: true,
    used: false,
    tags: ['tag:roachnet-companion'],
    capabilities: ['companion-bootstrap', 'runtime-status', 'app-install'],
  }
}

function issueRoachTailJoinCode() {
  const issuedAt = roachTailNow()
  const joinCode = generateRoachTailJoinCode()
  return {
    joinCode,
    joinCodeHash: roachTailHash(joinCode),
    joinCodeExpiresAt: roachTailAddMs(ROACHTAIL_JOIN_CODE_TTL_MS),
    pairingIssuedAt: issuedAt,
    preAuthKeys: [createRoachTailPreAuthKey(joinCode, issuedAt)],
  }
}

function defaultRoachTailState() {
  const enabled = wantsCompanionRuntime()
  const issued = enabled ? issueRoachTailJoinCode() : {}
  const relayHost = normalizeRoachTailRelayHost(process.env.ROACHTAIL_RELAY_HOST)
  const advertisedUrl = roachTailAdvertisedUrl(relayHost)
  const runtimeOrigin = roachTailRuntimeOrigin()
  return {
    schema: 'org.roachnet.roachtail.control-plane.v1',
    enabled,
    networkName: roachTailNetworkName(),
    namespace: roachTailNamespace(),
    deviceName: os.hostname(),
    deviceId: roachTailDeviceId(),
    machineKey: `mkey_${roachTailHash(`${storageRoot}:machine`).slice(0, 32)}`,
    nodeKey: `node_${roachTailHash(`${storageRoot}:node`).slice(0, 32)}`,
    status: enabled ? 'armed' : 'local-only',
    transportMode: enabled ? (relayHost ? 'tailnet-relay' : 'local-bridge') : 'local-only',
    secureOverlay: true,
    relayHost,
    advertisedUrl,
    runtimeOrigin,
    runtimeTunnelUrl: roachTailRuntimeTunnelUrl(relayHost, runtimeOrigin),
    joinCode: issued.joinCode || null,
    joinCodeHash: issued.joinCodeHash || null,
    joinCodeExpiresAt: issued.joinCodeExpiresAt || null,
    pairingPayload: null,
    pairingIssuedAt: issued.pairingIssuedAt || null,
    preAuthKeys: issued.preAuthKeys || [],
    peers: [],
    policy: {
      mode: 'local-owner',
      aclDefault: 'deny',
      ownerCanApproveRoutes: true,
      peerCanSelfRemove: true,
    },
    lastUpdatedAt: roachTailNow(),
    notes: enabled
      ? [
          'RoachTail is using a native RoachNet control plane shaped after Headscale: local node records, expiring join keys, route approval, and no user-content custody.',
          relayHost
            ? 'The bridge advertises a relay host instead of the raw machine address.'
            : 'Add a relay host when you want paired devices to avoid the raw local address.',
        ]
      : ['RoachTail is off in the dependency-free native bridge.'],
  }
}

function readRoachTailStateRaw({ persistIfMissing = false } = {}) {
  const state = readRoachTailStateFile()

  const fallback = defaultRoachTailState()
  const merged = {
    ...fallback,
    ...(state && typeof state === 'object' ? state : {}),
  }
  merged.schema = 'org.roachnet.roachtail.control-plane.v1'
  merged.networkName = String(merged.networkName || roachTailNetworkName())
  merged.namespace = String(merged.namespace || roachTailNamespace())
  merged.deviceName = String(merged.deviceName || os.hostname())
  merged.deviceId = String(merged.deviceId || roachTailDeviceId())
  merged.machineKey = String(merged.machineKey || fallback.machineKey)
  merged.nodeKey = String(merged.nodeKey || fallback.nodeKey)
  merged.relayHost = normalizeRoachTailRelayHost(merged.relayHost)
  merged.advertisedUrl = roachTailAdvertisedUrl(merged.relayHost, merged.advertisedUrl || roachTailBridgeUrl())
  merged.runtimeOrigin = merged.runtimeOrigin || roachTailRuntimeOrigin()
  merged.runtimeTunnelUrl = roachTailRuntimeTunnelUrl(merged.relayHost, merged.runtimeTunnelUrl || merged.runtimeOrigin)
  merged.peers = Array.isArray(merged.peers) ? merged.peers : []
  merged.preAuthKeys = Array.isArray(merged.preAuthKeys) ? merged.preAuthKeys : []
  merged.policy = merged.policy && typeof merged.policy === 'object' ? merged.policy : fallback.policy
  merged.transportMode = roachTailTransportModeFor(merged)
  merged.status = roachTailStatusFor(merged)
  merged.secureOverlay = true

  if (merged.enabled && (!isRoachTailJoinCodeFresh(merged) || !merged.joinCode)) {
    const issued = issueRoachTailJoinCode()
    merged.joinCode = issued.joinCode
    merged.joinCodeHash = issued.joinCodeHash
    merged.joinCodeExpiresAt = issued.joinCodeExpiresAt
    merged.pairingIssuedAt = issued.pairingIssuedAt
    merged.preAuthKeys = issued.preAuthKeys
    merged.lastUpdatedAt = roachTailNow()
    persistIfMissing = true
  }

  if (persistIfMissing && (!state || merged.enabled)) {
    writeRoachTailStateRaw(merged)
  }

  return merged
}

function writeRoachTailStateRaw(state) {
  const next = {
    ...state,
    transportMode: roachTailTransportModeFor(state),
    status: roachTailStatusFor(state),
    lastUpdatedAt: roachTailNow(),
  }
  mkdirSync(path.dirname(roachTailStatePath), { recursive: true })
  writeFileSync(roachTailStatePath, JSON.stringify(next, null, 2))
  return next
}

function isRoachTailJoinCodeFresh(state) {
  if (!state?.joinCode || !state?.joinCodeExpiresAt) return false
  const expiresAt = Date.parse(state.joinCodeExpiresAt)
  return Number.isFinite(expiresAt) && expiresAt > Date.now()
}

function roachTailRoutes(state) {
  const routes = []
  if (state.advertisedUrl) {
    routes.push({
      id: 'companion-bridge',
      type: 'service',
      target: state.advertisedUrl,
      approved: true,
      advertised: Boolean(state.enabled),
      primary: true,
      tags: ['tag:companion'],
      description: 'Companion control bridge for iPhone, iPad, and web chat carryover.',
    })
  }
  if (state.runtimeTunnelUrl) {
    routes.push({
      id: 'native-runtime',
      type: 'service',
      target: state.runtimeTunnelUrl,
      approved: true,
      advertised: Boolean(state.enabled),
      primary: false,
      tags: ['tag:runtime'],
      description: 'Read-only runtime status and install handoff route.',
    })
  }
  routes.push({
    id: 'local-tailnet-cidr',
    type: 'cidr',
    target: process.env.ROACHTAIL_TAILNET_CIDR?.trim() || '100.82.0.0/16',
    approved: true,
    advertised: Boolean(state.enabled),
    primary: false,
    tags: ['tag:roachnet'],
    description: 'Reserved RoachTail address space for local peer records.',
  })
  return routes
}

function roachTailDerpMap(state) {
  return {
    mode: state.relayHost ? 'custom-relay' : 'local-only',
    regions: [
      {
        id: state.relayHost ? 'roachnet-relay' : 'roachnet-local',
        name: state.relayHost ? 'RoachTail relay' : 'RoachTail local bridge',
        host: state.relayHost || process.env.ROACHNET_LOCAL_HOSTNAME || 'RoachNet',
        url: state.advertisedUrl,
        embedded: !state.relayHost,
      },
    ],
  }
}

function roachTailControlPlane(state) {
  return {
    provider: 'roachnet-native',
    designReference: 'headscale',
    namespace: state.namespace,
    nodeApproval: 'owner-local',
    routeApproval: 'owner-local',
    authKeyTtlSeconds: Math.round(ROACHTAIL_AUTH_KEY_TTL_MS / 1000),
    joinCodeTtlSeconds: Math.round(ROACHTAIL_JOIN_CODE_TTL_MS / 1000),
    policyMode: state.policy?.mode || 'local-owner',
    dnsName: `${state.deviceName}.roachtail.local`.toLowerCase().replace(/[^a-z0-9.-]/g, '-'),
  }
}

function sanitizeRoachTailPeer(peer) {
  return {
    id: String(peer.id || randomUUID()),
    name: String(peer.name || 'Linked device'),
    platform: String(peer.platform || 'unknown'),
    status: String(peer.status || 'paired'),
    endpoint: peer.endpoint || null,
    lastSeenAt: peer.lastSeenAt || null,
    allowsExitNode: Boolean(peer.allowsExitNode),
    tags: Array.isArray(peer.tags) ? peer.tags : ['tag:roachnet-companion'],
    nodeKey: peer.nodeKey || null,
    machineKey: peer.machineKey || null,
    routes: Array.isArray(peer.routes) ? peer.routes : [],
    capabilities: Array.isArray(peer.capabilities)
      ? peer.capabilities
      : ['companion-bootstrap', 'runtime-status', 'app-install'],
  }
}

function sanitizeRoachTailPreAuthKey(key) {
  return {
    id: String(key.id || ''),
    createdAt: key.createdAt || null,
    expiresAt: key.expiresAt || null,
    reusable: Boolean(key.reusable),
    ephemeral: key.ephemeral !== false,
    used: Boolean(key.used),
    tags: Array.isArray(key.tags) ? key.tags : [],
    capabilities: Array.isArray(key.capabilities) ? key.capabilities : [],
  }
}

function sanitizeRoachTailState(state, options = {}) {
  const hiddenJoinCode = options.hideJoinCode ? null : state.joinCode || null
  const displayState = {
    ...state,
    joinCode: hiddenJoinCode,
    joinCodeHash: undefined,
    pairingPayload: hiddenJoinCode ? buildRoachTailPairingPayload(state) : null,
    peers: state.peers.map(sanitizeRoachTailPeer),
    preAuthKeys: state.preAuthKeys.map(sanitizeRoachTailPreAuthKey),
    routes: roachTailRoutes(state),
    derpMap: roachTailDerpMap(state),
    controlPlane: roachTailControlPlane(state),
  }
  delete displayState.joinCodeHash
  return displayState
}

function buildRoachTailPairingPayload(state) {
  if (!state.enabled || !state.joinCode || !isRoachTailJoinCodeFresh(state)) return null
  return JSON.stringify({
    schema: 'roachnet.roachtail.v2',
    networkName: state.networkName,
    namespace: state.namespace,
    deviceName: state.deviceName,
    deviceId: state.deviceId,
    joinCode: state.joinCode,
    joinCodeExpiresAt: state.joinCodeExpiresAt,
    bridgeUrl: state.advertisedUrl,
    runtimeTunnelUrl: state.runtimeTunnelUrl,
    controlPlane: roachTailControlPlane(state),
    routes: roachTailRoutes(state).filter((route) => route.approved && route.advertised),
  })
}

function roachTailState(options = {}) {
  return sanitizeRoachTailState(readRoachTailStateRaw({ persistIfMissing: true }), options)
}

function roachTailPeerFromPayload(payload, tokenHash = null) {
  const now = roachTailNow()
  const name = String(payload.peerName || payload.name || payload.deviceName || 'Linked device')
    .trim()
    .slice(0, 80) || 'Linked device'
  const platform = String(payload.platform || payload.os || 'unknown').trim().slice(0, 48) || 'unknown'
  return {
    id: String(payload.peerId || payload.id || `rtpeer_${randomUUID().replaceAll('-', '').slice(0, 16)}`),
    name,
    platform,
    status: 'paired',
    endpoint: payload.endpoint ? String(payload.endpoint).trim().slice(0, 180) : null,
    lastSeenAt: now,
    allowsExitNode: Boolean(payload.allowsExitNode),
    tags: Array.isArray(payload.tags) && payload.tags.length > 0 ? payload.tags.map(String) : ['tag:roachnet-companion'],
    nodeKey: String(payload.nodeKey || `node_${roachTailHash(`${name}:${platform}:${now}`).slice(0, 32)}`),
    machineKey: String(payload.machineKey || `mkey_${roachTailHash(`${platform}:${name}:${now}`).slice(0, 32)}`),
    routes: Array.isArray(payload.routes) ? payload.routes : [],
    capabilities: Array.isArray(payload.capabilities) && payload.capabilities.length > 0
      ? payload.capabilities.map(String)
      : ['companion-bootstrap', 'runtime-status', 'app-install'],
    tokenHash,
    preAuthKeyId: payload.preAuthKeyId || null,
    createdAt: now,
  }
}

function mutateRoachTailState(action, payload = {}, request = null) {
  const current = readRoachTailStateRaw({ persistIfMissing: true })
  let next = {
    ...current,
    peers: [...current.peers],
    preAuthKeys: [...current.preAuthKeys],
  }
  const normalizedAction = String(action || '').trim()
  const peerAuthKind = request?.headers?.['x-roachtail-auth-kind']?.trim?.().toLowerCase()
  const authPeerId = request?.headers?.['x-roachtail-auth-peer-id']?.trim?.() || null
  const peerScoped = peerAuthKind === 'peer'

  if (peerScoped && !['remove-peer'].includes(normalizedAction)) {
    throw new NativeApiRequestError('Peer-scoped RoachTail changes can only remove that paired device.', 403)
  }

  switch (normalizedAction) {
    case 'enable': {
      const issued = issueRoachTailJoinCode()
      next.enabled = true
      next.relayHost = normalizeRoachTailRelayHost(payload.relayHost) || next.relayHost
      next.joinCode = issued.joinCode
      next.joinCodeHash = issued.joinCodeHash
      next.joinCodeExpiresAt = issued.joinCodeExpiresAt
      next.pairingIssuedAt = issued.pairingIssuedAt
      next.preAuthKeys = issued.preAuthKeys
      next.notes = [
        'RoachTail is armed with a native RoachNet control plane: expiring join key, local node registry, approved service routes, and private peer tokens.',
        next.relayHost
          ? 'Relay mode is active, so paired devices should use the relay host instead of the raw local bridge.'
          : 'Local bridge mode is active. Add a relay host when you need remote devices off the raw machine address.',
      ]
      break
    }
    case 'disable':
      next.enabled = false
      next.joinCode = null
      next.joinCodeHash = null
      next.joinCodeExpiresAt = null
      next.pairingPayload = null
      next.preAuthKeys = next.preAuthKeys.map((key) => ({ ...key, used: true }))
      next.notes = [
        'RoachTail is disabled. Existing peer records are kept so the private lane can be re-armed without rebuilding every device link.',
      ]
      break
    case 'refresh-join-code': {
      const issued = issueRoachTailJoinCode()
      next.enabled = true
      next.joinCode = issued.joinCode
      next.joinCodeHash = issued.joinCodeHash
      next.joinCodeExpiresAt = issued.joinCodeExpiresAt
      next.pairingIssuedAt = issued.pairingIssuedAt
      next.preAuthKeys = issued.preAuthKeys
      next.notes = [
        'RoachTail issued a fresh one-use join key.',
        'The old pairing window is closed; scan the new payload from the device you are adding.',
      ]
      break
    }
    case 'clear-peers':
      next.peers = []
      next.notes = [
        'RoachTail peer records were cleared from the local control plane.',
        'Refresh the join key when you are ready to add devices again.',
      ]
      break
    case 'set-relay-host':
      next.relayHost = normalizeRoachTailRelayHost(payload.relayHost)
      next.notes = [
        next.relayHost
          ? `RoachTail will advertise the relay host ${next.relayHost}.`
          : 'RoachTail relay host was cleared and the bridge will use the local advertised URL.',
      ]
      break
    case 'register-peer': {
      const peerToken = generateRoachTailSecret('rtp')
      const peer = roachTailPeerFromPayload(payload, roachTailHash(peerToken))
      next.enabled = true
      next.peers = [...next.peers.filter((item) => item.id !== peer.id), peer]
      next.notes = [
        `${peer.name} was registered in the RoachTail control plane.`,
        'Store the peer token once; RoachNet only keeps its hash.',
      ]
      next = writeRoachTailStateRaw(finalizeRoachTailState(next))
      return {
        success: true,
        ok: true,
        message: `${peer.name} registered with RoachTail.`,
        token: peerToken,
        peerId: peer.id,
        peerToken,
        state: sanitizeRoachTailState(next),
      }
    }
    case 'remove-peer': {
      const peerId = peerScoped ? authPeerId : String(payload.peerId || '').trim()
      if (!peerId) throw new NativeApiRequestError('A peerId is required to remove a RoachTail peer.', 400)
      next.peers = next.peers.filter((peer) => peer.id !== peerId)
      next.notes = [
        'RoachTail removed one peer from the local control plane.',
        next.peers.length > 0
          ? `${next.peers.length} linked peer${next.peers.length === 1 ? '' : 's'} remain.`
          : 'No linked peers remain. Refresh the join key before adding another device.',
      ]
      break
    }
    default:
      throw new NativeApiRequestError('RoachTail action must be enable, disable, refresh-join-code, clear-peers, set-relay-host, register-peer, or remove-peer.', 400)
  }

  next = writeRoachTailStateRaw(finalizeRoachTailState(next))
  return {
    success: true,
    ok: true,
    message: roachTailActionMessage(normalizedAction, next),
    state: sanitizeRoachTailState(next, { hideJoinCode: peerScoped }),
  }
}

function finalizeRoachTailState(state) {
  const relayHost = normalizeRoachTailRelayHost(state.relayHost)
  return {
    ...state,
    relayHost,
    advertisedUrl: roachTailAdvertisedUrl(relayHost, state.advertisedUrl || roachTailBridgeUrl()),
    runtimeOrigin: state.runtimeOrigin || roachTailRuntimeOrigin(),
    runtimeTunnelUrl: roachTailRuntimeTunnelUrl(relayHost, state.runtimeTunnelUrl || state.runtimeOrigin || roachTailRuntimeOrigin()),
    secureOverlay: true,
  }
}

function roachTailActionMessage(action, state) {
  switch (action) {
    case 'enable':
      return 'RoachTail armed with a fresh join key.'
    case 'disable':
      return 'RoachTail disabled.'
    case 'refresh-join-code':
      return 'RoachTail join key refreshed.'
    case 'clear-peers':
      return 'RoachTail peers cleared.'
    case 'set-relay-host':
      return state.relayHost ? 'RoachTail relay host updated.' : 'RoachTail relay host cleared.'
    case 'remove-peer':
      return 'RoachTail peer removed.'
    default:
      return 'RoachTail updated.'
  }
}

function pairRoachTailPeer(payload = {}) {
  const current = readRoachTailStateRaw({ persistIfMissing: true })
  if (!current.enabled) {
    throw new NativeApiRequestError('RoachTail is off on this desktop. Turn it on before pairing a device.', 409)
  }
  if (!isRoachTailJoinCodeFresh(current)) {
    throw new NativeApiRequestError('That RoachTail join code expired. Refresh the code on the desktop and try again.', 401)
  }
  const joinCode = String(payload.joinCode || '').trim().toUpperCase()
  if (!joinCode || roachTailHash(joinCode) !== current.joinCodeHash) {
    throw new NativeApiRequestError('That RoachTail join code does not match this desktop.', 401)
  }

  const peerToken = generateRoachTailSecret('rtp')
  const activeKey = current.preAuthKeys.find((key) => key.keyHash === current.joinCodeHash)
  const peer = roachTailPeerFromPayload(
    {
      ...payload,
      preAuthKeyId: activeKey?.id || null,
    },
    roachTailHash(peerToken)
  )
  const next = writeRoachTailStateRaw(finalizeRoachTailState({
    ...current,
    enabled: true,
    peers: [...current.peers.filter((item) => item.id !== peer.id), peer],
    preAuthKeys: current.preAuthKeys.map((key) =>
      key.keyHash === current.joinCodeHash ? { ...key, used: true, usedAt: roachTailNow(), usedBy: peer.id } : key
    ),
    notes: [
      `${peer.name} paired over RoachTail.`,
      'This device now has its own private bridge token for chat carryover, runtime control, and App Store installs.',
      'Refresh the join key if you want to close the current pairing window and mint a new one.',
    ],
  }))

  return {
    success: true,
    ok: true,
    message: `${peer.name} paired with RoachTail.`,
    // `token` and `peerId` are the v1.0.5 contract that shipped iOS companions decode.
    token: peerToken,
    peerId: peer.id,
    peerToken,
    bridgeUrl: next.advertisedUrl,
    runtimeTunnelUrl: next.runtimeTunnelUrl,
    state: sanitizeRoachTailState(next),
  }
}

function roachSyncState() {
  return {
    enabled: false,
    provider: 'local',
    networkName: 'RoachSync',
    deviceName: os.hostname(),
    deviceId: os.hostname(),
    status: 'local-only',
    folderId: 'roachnet-storage',
    folderPath: storageRoot,
    guiUrl: null,
    apiUrl: null,
    transportMode: 'native-local',
    secureOverlay: true,
    notes: ['RoachSync is available when the user arms the companion lane.'],
    peers: [],
    lastUpdatedAt: null,
  }
}

const serviceCatalog = [
  {
    service_name: 'roachnet_kiwix_serve',
    friendly_name: 'RoachNet Library',
    description: 'Offline encyclopedias, field manuals, and reference archives staged inside RoachNet.',
    icon: 'IconBooks',
    powered_by: 'Kiwix',
    ui_location: '8090',
    display_order: 1,
  },
  {
    service_name: 'roachnet_kolibri',
    friendly_name: 'RoachNet Academy',
    description: 'Structured offline education content and coursework surfaced through RoachNet.',
    icon: 'IconSchool',
    powered_by: 'Kolibri',
    ui_location: '8300',
    display_order: 2,
  },
  {
    service_name: 'roachnet_ollama',
    friendly_name: 'RoachNet Chat',
    description: 'Local AI chat and model tooling managed from the RoachNet command grid.',
    icon: 'IconWand',
    powered_by: 'Ollama',
    ui_location: '/chat',
    display_order: 3,
  },
  {
    service_name: 'roachnet_roachsync',
    friendly_name: 'RoachSync',
    description: 'Private sync for the RoachNet vault, settings, and future shared installs.',
    icon: 'IconArrowsExchange',
    powered_by: 'Native companion bridge',
    ui_location: '8384',
    display_order: 4,
  },
  {
    service_name: 'roachnet_flatnotes',
    friendly_name: 'RoachNet Notes',
    description: 'Fast local notes for fragments, checklists, and working references on the same machine.',
    icon: 'IconNotes',
    powered_by: 'Flat file vault',
    ui_location: '/vault',
    display_order: 10,
  },
  {
    service_name: 'roachnet_cyberchef',
    friendly_name: 'RoachNet Data Lab',
    description: 'Encoding, decoding, and analysis tools adapted for RoachNet field workflows.',
    icon: 'IconChefHat',
    powered_by: 'Native utilities',
    ui_location: '/dev',
    display_order: 11,
  },
]

async function systemServices(ollamaStatus = null) {
  const ollama = ollamaStatus || await providerStatus('ollama', ollamaBaseUrl)
  return serviceCatalog.map((service) => {
    const isOllama = service.service_name === 'roachnet_ollama'
    const nativeInstalled = isOllama ? ollama.available : ['roachnet_flatnotes', 'roachnet_cyberchef'].includes(service.service_name)
    return {
      ...service,
      installed: nativeInstalled,
      installation_status: nativeInstalled ? 'installed' : 'idle',
      status: nativeInstalled ? 'running' : 'available',
    }
  })
}

async function companionBootstrapState() {
  return {
    appName: 'RoachNet',
    machineName: os.hostname(),
    appsCatalogUrl: 'https://apps.roachnet.org/app-store-catalog.json',
    sessions: [],
    account: accountState(),
    runtime: await companionRuntimeState(),
    vault: companionVaultState(),
  }
}

async function companionRuntimeState() {
  const status = await roachClawStatus()
  const system = systemInfo()
  const services = await systemServices(status.ollama)
  const models = Array.isArray(status.modelRecords)
    ? status.modelRecords
    : (status.installedModels || []).map((name) => ({ name, size: null }))
  const issues = []
  if (!status.ollama.available) {
    issues.push({
      path: '/api/ollama',
      error: 'Ollama is not reachable yet; local chat will warm up after the runner starts.',
    })
  }
  if (!models.length) {
    issues.push({
      path: '/api/ollama/installed-models',
      error: 'No local model packs are installed yet.',
    })
  }

  return {
    systemInfo: system,
    system,
    providers: {
      providers: {
        ollama: status.ollama,
        openclaw: status.openclaw,
        roachclawNativeAgent: {
          provider: 'roachclawNativeAgent',
          available: true,
          source: 'native-api',
          baseUrl: null,
          error: null,
          native: true,
          runtime: status.agent.runtime,
        },
      },
    },
    roachClaw: status,
    account: accountState(),
    roachTail: roachTailState({ hideJoinCode: true }),
    roachSync: roachSyncState(),
    services,
    downloads: downloadJobs,
    installedModels: models,
    issues,
    benchmark: benchmarkStatus,
  }
}

function companionVaultState() {
  const vaultPath = path.join(storageRoot, 'Vault')
  return {
    vaultPath,
    knowledgeFiles: listVaultKnowledgeFiles(vaultPath),
    roachBrain: [],
  }
}

function listFiles(root, limit = 80) {
  const out = []
  function walk(current) {
    if (out.length >= limit || !existsSync(current)) return
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name)
      if (entry.isDirectory()) {
        walk(full)
      } else if (entry.isFile()) {
        out.push(path.relative(root, full))
      }
      if (out.length >= limit) return
    }
  }
  walk(root)
  return out
}

function listVaultKnowledgeFiles(root, limit = 80) {
  const out = []
  function walk(current, relativeRoot = '') {
    if (out.length >= limit || !existsSync(current)) return
    const entries = readdirSync(current, { withFileTypes: true })
      .sort((left, right) => left.name.localeCompare(right.name))
    for (const entry of entries) {
      const relativePath = relativeRoot ? path.join(relativeRoot, entry.name) : entry.name
      if (isReservedVaultPath(relativePath)) continue
      const full = path.join(current, entry.name)
      if (entry.isDirectory()) {
        walk(full, relativePath)
      } else if (entry.isFile()) {
        out.push(relativePath)
      }
      if (out.length >= limit) return
    }
  }
  walk(root)
  return out
}

function isReservedVaultPath(relativePath) {
  return /^(?:roachtail|roachclaw)(?:[\\/]|$)/i.test(relativePath)
}

function mapCollections() {
  const manifest = readJsonFile([
    'collections/maps.json',
    'website-apps-dist/collections/maps.json',
  ], { collections: [] })
  const mapsRoot = path.join(storageRoot, 'maps', 'pmtiles')

  return (manifest.collections || []).map((collection) => {
    const resources = (collection.resources || []).map((resource) => ({
      id: resource.id,
      title: resource.title,
      size_mb: resource.size_mb ?? null,
      description: resource.description ?? null,
      url: resource.url ?? null,
      descriptorUrl: resource.url ? descriptorUrlForSource(resource.url, 'maps/pmtiles') : null,
    }))
    const installedCount = resources.filter((resource) => {
      const filename = resource.url ? fileNameForUrl(resource.url, `${resource.id}.pmtiles`) : `${resource.id}.pmtiles`
      return existsSync(path.join(mapsRoot, filename))
    }).length

    return {
      slug: collection.slug,
      name: collection.name,
      description: collection.description ?? null,
      installed_count: installedCount,
      total_count: resources.length,
      resources,
    }
  })
}

function educationCategories() {
  const manifest = readJsonFile([
    'collections/kiwix-categories.json',
    'website-apps-dist/collections/kiwix-categories.json',
  ], { categories: [] })
  const zimRoot = path.join(storageRoot, 'zim')

  return (manifest.categories || []).map((category) => ({
    slug: category.slug,
    name: category.name,
    description: category.description ?? null,
    installedTierSlug: installedTierSlug(category, zimRoot),
    tiers: (category.tiers || []).map((tier) => ({
      name: tier.name,
      slug: tier.slug,
      description: tier.description ?? null,
      recommended: Boolean(tier.recommended),
      resources: (tier.resources || []).filter((resource) => !resource.unavailable).map((resource) => ({
        id: resource.id,
        title: resource.title,
        size_mb: resource.size_mb ?? null,
        description: resource.description ?? null,
        url: resource.url ?? null,
        descriptorUrl: resource.url ? descriptorUrlForSource(resource.url, 'content/zim') : null,
      })),
    })),
  }))
}

function installedTierSlug(category, zimRoot) {
  for (const tier of category.tiers || []) {
    const hasInstalledResource = (tier.resources || []).some((resource) => {
      if (!resource.url) return false
      return existsSync(path.join(zimRoot, fileNameForUrl(resource.url, `${resource.id}.zim`)))
    })
    if (hasInstalledResource) return tier.slug
  }
  return null
}

function wikipediaOptions() {
  return readJsonFile([
    'collections/wikipedia.json',
    'website-apps-dist/collections/wikipedia.json',
  ], { options: [] }).options?.filter((option) => !option.unavailable) || []
}

function wikipediaSelectionPath() {
  return path.join(storageRoot, 'zim', 'wikipedia-selection.json')
}

function wikipediaState() {
  let currentSelection = null
  try {
    currentSelection = JSON.parse(readFileSync(wikipediaSelectionPath(), 'utf8'))
  } catch {}

  return {
    options: wikipediaOptions().map((option) => ({
      id: option.id,
      name: option.name,
      description: option.description ?? null,
      size_mb: option.size_mb ?? null,
      url: option.url ?? null,
      descriptorUrl: option.url ? descriptorUrlForSource(option.url, 'content/wikipedia') : null,
    })),
    currentSelection,
  }
}

function siteArchives() {
  const records = readJsonFile([
    path.join(storageRoot, 'site-archives', 'index.json'),
    'storage/site-archives/index.json',
    'admin/storage/site-archives/index.json',
  ], [])

  return (Array.isArray(records) ? records : []).map((archive) => ({
    slug: archive.slug,
    title: archive.title ?? archive.slug,
    url: archive.url ?? archive.sourceUrl ?? archive.entryUrl ?? null,
    createdAt: archive.createdAt ?? null,
  })).filter((archive) => archive.slug)
}

function safeFileName(value, fallback = 'download.bin') {
  const cleaned = String(value || '')
    .trim()
    .replace(/[^\w.\- ]+/g, '_')
    .replace(/\s+/g, '-')
    .slice(0, 160)
  return cleaned || fallback
}

function fileNameForUrl(rawUrl, fallback) {
  try {
    const parsed = new URL(rawUrl)
    return safeFileName(path.basename(parsed.pathname), fallback)
  } catch {
    return fallback
  }
}

function descriptorUrlForSource(rawUrl, prefix) {
  try {
    const parsed = new URL(rawUrl)
    const basename = path.basename(parsed.pathname)
    if (!basename) return rawUrl
    const descriptorName = basename.replace(/\.[^/.]+$/i, '.json')
    return `${appsDownloadsBaseUrl.replace(/\/+$/, '')}/${prefix}/${descriptorName}`
  } catch {
    return rawUrl
  }
}

function queueDownload(rawUrl, destinationDirectory, filetype, options = {}) {
  const url = parseDownloadUrl(rawUrl)
  if (!url) return null
  mkdirSync(destinationDirectory, { recursive: true })
  const filename = safeFileName(options.filename || fileNameForUrl(url, `${randomUUID()}.${filetype || 'download'}`), `${randomUUID()}.${filetype || 'download'}`)
  const filepath = path.join(destinationDirectory, filename)
  const activeJob = downloadJobs.find((job) =>
    job.url === url &&
    job.filepath === filepath &&
    ['queued', 'downloading'].includes(job.status)
  )

  if (activeJob) {
    return activeJob
  }

  const job = {
    jobId: randomUUID(),
    url,
    progress: 0,
    filepath,
    partialFilepath: `${filepath}.part`,
    filetype,
    status: 'queued',
    failedReason: null,
    descriptorUrl: options.descriptorUrl || null,
    expectedSha256: options.expectedSha256 || null,
    parts: Array.isArray(options.parts) ? options.parts : [],
    totalBytes: null,
    bytesReceived: 0,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    completedAt: null,
    installPath: null,
    installStatus: null,
    afterDownload: options.afterDownload,
  }
  downloadJobs = [job, ...downloadJobs].slice(0, 200)
  downloadFile(job).catch((error) => {
    job.status = 'failed'
    job.failedReason = error.message
    job.progress = 0
    log(`download failed ${job.jobId}: ${error.message}`)
  })
  return job
}

async function queueResolvedDownload(rawUrl, destinationDirectory, filetype, options = {}) {
  const resolvedDownload = await resolveDownloadDescriptor(rawUrl)
  if (!resolvedDownload.url) return null
  return queueDownload(resolvedDownload.url, destinationDirectory, filetype, {
    ...options,
    descriptorUrl: resolvedDownload.descriptorUrl,
    expectedSha256: resolvedDownload.sha256,
    filename: resolvedDownload.filename,
    parts: resolvedDownload.parts,
  })
}

function mirrorDownloadJobToUpdateStatus(job, release) {
  const timer = setInterval(() => {
    if (job.status === 'completed') {
      systemUpdateStatus = updateStatus(
        'ready',
        100,
        `Installer downloaded to ${job.filepath}. Run RoachNet Setup over the existing install.`
      )
      clearInterval(timer)
      if (process.platform === 'darwin' && process.env.ROACHNET_OPEN_UPDATES !== '0') {
        spawn('open', [job.filepath], { detached: true, stdio: 'ignore' }).unref()
      }
      return
    }

    if (job.status === 'failed') {
      systemUpdateStatus = updateStatus('error', 0, job.failedReason || 'Update download failed.')
      clearInterval(timer)
      return
    }

    systemUpdateStatus = updateStatus(
      'downloading',
      job.progress,
      `Downloading ${release.name || release.latestVersion}.`
    )
  }, 750)
}

function modelPacksRootPath() {
  return path.join(storageRoot, 'RoachSpeech', 'ModelPacks')
}

function readRoachSpeechPackRegistry() {
  return readJsonFile([path.join(modelPacksRootPath(), 'pending-packs.json')], [])
}

function writeRoachSpeechPackRegistry(nextRegistry) {
  const registryPath = path.join(modelPacksRootPath(), 'pending-packs.json')
  mkdirSync(path.dirname(registryPath), { recursive: true })
  writeFileSync(registryPath, JSON.stringify(nextRegistry, null, 2))
}

function upsertRoachSpeechPackRegistry(entry) {
  const registry = readRoachSpeechPackRegistry()
  const nextRegistry = [
    {
      ...entry,
      updatedAt: new Date().toISOString(),
    },
    ...(Array.isArray(registry) ? registry.filter((item) => item.packID !== entry.packID) : []),
  ].slice(0, 50)
  writeRoachSpeechPackRegistry(nextRegistry)
}

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256')
    const stream = createReadStream(filePath)
    stream.on('error', reject)
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('end', () => resolve(hash.digest('hex')))
  })
}

function runQuiet(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd || repoRoot,
      env: options.env || process.env,
      stdio: options.stdio || 'pipe',
    })
    let stderr = ''
    child.stderr?.on('data', (chunk) => {
      stderr += chunk.toString()
    })
    child.on('error', reject)
    child.on('close', (code) => {
      if (code === 0) {
        resolve()
      } else {
        reject(new Error(`${command} ${args.join(' ')} failed with exit code ${code}${stderr ? `: ${stderr}` : ''}`))
      }
    })
  })
}

function findRoachSpeechPackRoot(candidateRoot, depth = 0) {
  const manifestPath = path.join(candidateRoot, 'RoachSpeechPack.json')
  if (existsSync(manifestPath)) {
    return candidateRoot
  }

  if (depth >= 4) {
    return null
  }

  let entries = []
  try {
    entries = readdirSync(candidateRoot, { withFileTypes: true })
  } catch {
    return null
  }

  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) {
      continue
    }
    const found = findRoachSpeechPackRoot(path.join(candidateRoot, entry.name), depth + 1)
    if (found) {
      return found
    }
  }
  return null
}

function validateRoachSpeechPackRoot(packRoot, expectedPackID, expectedKind) {
  const manifestPath = path.join(packRoot, 'RoachSpeechPack.json')
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  if (manifest.packID !== expectedPackID) {
    throw new Error(`RoachSpeech pack mismatch. Expected ${expectedPackID}, found ${manifest.packID || 'missing'}.`)
  }
  if (expectedKind && manifest.kind !== expectedKind) {
    throw new Error(`RoachSpeech pack kind mismatch. Expected ${expectedKind}, found ${manifest.kind || 'missing'}.`)
  }
  if (manifest.noPackagedBinary !== true || manifest.nativeFormat !== 'coreML') {
    throw new Error(`${expectedPackID} is not a native Core ML RoachSpeech pack.`)
  }
  return manifest
}

async function installRoachSpeechPackArchive(job, packID, kind) {
  const packsRoot = modelPacksRootPath()
  mkdirSync(packsRoot, { recursive: true })
  const extractRoot = mkdtempSync(path.join(packsRoot, `.extract-${packID}-`))
  const finalRoot = path.join(packsRoot, packID)
  const stagingRoot = path.join(packsRoot, `.staging-${packID}-${randomUUID()}`)
  const backupRoot = path.join(packsRoot, `.backup-${packID}-${randomUUID()}`)

  try {
    if (!statSync(job.filepath).isFile()) {
      throw new Error(`Downloaded RoachSpeech pack is not a file: ${job.filepath}`)
    }
    await runQuiet('ditto', ['-x', '-k', job.filepath, extractRoot])
    const packRoot = findRoachSpeechPackRoot(extractRoot)
    if (!packRoot) {
      throw new Error('Downloaded archive did not contain a RoachSpeechPack.json manifest.')
    }

    validateRoachSpeechPackRoot(packRoot, packID, kind)
    renameSync(packRoot, stagingRoot)
    if (existsSync(finalRoot)) {
      renameSync(finalRoot, backupRoot)
    }
    renameSync(stagingRoot, finalRoot)
    rmSync(backupRoot, { recursive: true, force: true })
    job.installPath = finalRoot
    job.installStatus = 'installed'
    upsertRoachSpeechPackRegistry({
      packID,
      kind,
      url: job.url,
      status: 'installed',
      filepath: job.filepath,
      installPath: finalRoot,
    })
  } catch (error) {
    if (existsSync(backupRoot) && !existsSync(finalRoot)) {
      renameSync(backupRoot, finalRoot)
    }
    job.installStatus = 'failed'
    upsertRoachSpeechPackRegistry({
      packID,
      kind,
      url: job.url,
      status: 'failed',
      filepath: job.filepath,
      installPath: existsSync(finalRoot) ? finalRoot : null,
      error: error instanceof Error ? error.message : String(error),
    })
    throw error
  } finally {
    rmSync(extractRoot, { recursive: true, force: true })
    rmSync(stagingRoot, { recursive: true, force: true })
    rmSync(backupRoot, { recursive: true, force: true })
  }
}

async function requestUpdateDownload(force = false) {
  systemUpdateStatus = updateStatus('checking', 5, 'Checking RoachNet releases.')
  const release = await resolveLatestRelease({ force })
  const updateAvailable = compareVersions(release.latestVersion, packageJson.version) > 0

  if (!updateAvailable) {
    systemUpdateStatus = updateStatus('idle', 100, 'RoachNet is current.')
    return {
      success: true,
      message: 'RoachNet is current.',
      note: release.pageUrl,
    }
  }

  if (!release.assetUrl || !/^https?:\/\//i.test(release.assetUrl)) {
    systemUpdateStatus = updateStatus('error', 0, 'No downloadable installer asset was found.')
    return {
      success: false,
      error: 'No downloadable installer asset was found.',
      note: release.pageUrl,
    }
  }

  const job = queueDownload(release.assetUrl, path.join(storageRoot, 'updates'), 'dmg')
  if (!job) {
    systemUpdateStatus = updateStatus('error', 0, 'Update download could not be queued.')
    return { success: false, error: 'Update download could not be queued.' }
  }

  systemUpdateStatus = updateStatus('downloading', 1, `Downloading ${release.name || release.latestVersion}.`)
  mirrorDownloadJobToUpdateStatus(job, release)
  return {
    success: true,
    message: `RoachNet ${release.latestVersion} installer download queued.`,
    note: job.filepath,
  }
}

async function writeDownloadChunk(file, chunk) {
  if (!file.write(Buffer.from(chunk))) {
    await once(file, 'drain')
  }
}

function decodeChunkPayload(part, body) {
  if (part.encoding !== 'roachnet-ia-chunk-v1') {
    return body
  }

  const header = Buffer.from(part.header || '', 'utf8')
  if (header.length === 0 || body.length < header.length || !body.subarray(0, header.length).equals(header)) {
    throw new Error(`Chunk ${part.index + 1} did not contain the expected RoachNet IA envelope.`)
  }
  return body.subarray(header.length)
}

async function downloadChunkedFile(job, file, controller) {
  const total = job.parts.reduce((sum, part) => sum + Number(part.bytes || 0), 0)
  job.totalBytes = total > 0 ? total : null
  if (total > NATIVE_API_MAX_DOWNLOAD_BYTES) {
    throw new Error(`Download is larger than the configured ${NATIVE_API_MAX_DOWNLOAD_BYTES} byte limit.`)
  }

  let received = 0
  for (const part of job.parts) {
    const expectedTransferBytes = part.encodedBytes || part.bytes
    const response = await fetch(part.url, {
      signal: controller.signal,
      headers: { 'user-agent': `RoachNet/${packageJson.version} native-downloader chunked` },
    })
    if (!response.ok || !response.body) {
      throw new Error(`HTTP ${response.status} while downloading ${part.url}`)
    }

    const partContentLength = Number(response.headers.get('content-length') || 0)
    if (partContentLength > 0 && partContentLength !== expectedTransferBytes) {
      throw new Error(`Chunk ${part.index + 1} reported ${partContentLength} bytes, expected ${expectedTransferBytes}.`)
    }

    const body = Buffer.from(await response.arrayBuffer())
    if (body.length !== expectedTransferBytes) {
      throw new Error(`Chunk ${part.index + 1} ended early after ${body.length} of ${expectedTransferBytes} bytes.`)
    }

    const payload = decodeChunkPayload(part, body)
    if (payload.length !== part.bytes) {
      throw new Error(`Chunk ${part.index + 1} decoded to ${payload.length} bytes, expected ${part.bytes}.`)
    }

    const actualPartSha256 = createHash('sha256').update(payload).digest('hex')
    if (part.sha256 && actualPartSha256 !== part.sha256) {
      throw new Error(`Chunk checksum mismatch for ${part.url}. Expected ${part.sha256}, found ${actualPartSha256}.`)
    }
    received += payload.length
    job.bytesReceived = received
    job.updatedAt = new Date().toISOString()
    if (received > NATIVE_API_MAX_DOWNLOAD_BYTES) {
      throw new Error(`Download exceeded the configured ${NATIVE_API_MAX_DOWNLOAD_BYTES} byte limit.`)
    }
    if (job.totalBytes) {
      job.progress = Math.max(1, Math.min(99, Math.round((received / job.totalBytes) * 100)))
    }
    await writeDownloadChunk(file, payload)
  }

  if (job.totalBytes && received !== job.totalBytes) {
    throw new Error(`Chunked download ended early after ${received} of ${job.totalBytes} bytes.`)
  }
}

async function downloadFile(job) {
  job.status = 'downloading'
  const controller = new AbortController()
  job.abort = () => controller.abort()
  const timeout = setTimeout(() => controller.abort(), NATIVE_API_DOWNLOAD_TIMEOUT_MS)
  let file = null

  try {
    rmSync(job.partialFilepath, { force: true })
    job.updatedAt = new Date().toISOString()
    file = createWriteStream(job.partialFilepath)

    if (Array.isArray(job.parts) && job.parts.length > 0) {
      await downloadChunkedFile(job, file, controller)
    } else {
      const response = await fetch(job.url, {
        signal: controller.signal,
        headers: { 'user-agent': `RoachNet/${packageJson.version} native-downloader` },
      })
      if (!response.ok || !response.body) {
        throw new Error(`HTTP ${response.status} while downloading ${job.url}`)
      }

      const total = Number(response.headers.get('content-length') || 0)
      job.totalBytes = total > 0 ? total : null
      if (total > NATIVE_API_MAX_DOWNLOAD_BYTES) {
        throw new Error(`Download is larger than the configured ${NATIVE_API_MAX_DOWNLOAD_BYTES} byte limit.`)
      }

      const reader = response.body.getReader()
      let received = 0

      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        received += value.byteLength
        job.bytesReceived = received
        job.updatedAt = new Date().toISOString()
        if (received > NATIVE_API_MAX_DOWNLOAD_BYTES) {
          throw new Error(`Download exceeded the configured ${NATIVE_API_MAX_DOWNLOAD_BYTES} byte limit.`)
        }
        if (total > 0) {
          job.progress = Math.max(1, Math.min(99, Math.round((received / total) * 100)))
        }
        await writeDownloadChunk(file, value)
      }
      if (total > 0 && received !== total) {
        throw new Error(`Download ended early after ${received} of ${total} bytes.`)
      }
    }
    file.end()
    await once(file, 'finish')
    renameSync(job.partialFilepath, job.filepath)
    if (job.expectedSha256) {
      const actualSha256 = await sha256File(job.filepath)
      if (actualSha256 !== job.expectedSha256) {
        throw new Error(`Checksum mismatch for ${job.url}. Expected ${job.expectedSha256}, found ${actualSha256}.`)
      }
      job.sha256 = actualSha256
    }
    if (typeof job.afterDownload === 'function') {
      job.status = 'installing'
      job.installStatus = 'installing'
      job.progress = 99
      job.updatedAt = new Date().toISOString()
      await job.afterDownload(job)
    }
    job.progress = 100
    job.status = 'completed'
    job.installStatus = job.installStatus || 'downloaded'
    job.completedAt = new Date().toISOString()
    job.updatedAt = job.completedAt
  } catch (error) {
    const wasCancelled = job.status === 'cancelled'
    closeFileStream(file)
    rmSync(job.partialFilepath, { force: true })
    rmSync(job.filepath, { force: true })
    job.updatedAt = new Date().toISOString()
    if (wasCancelled) {
      job.progress = 0
      job.completedAt = job.updatedAt
      return
    }
    throw new Error(abortErrorMessage(error, `Download from ${job.url}`))
  } finally {
    clearTimeout(timeout)
    delete job.abort
  }
}

function resourcesForMapCollection(slug) {
  const collection = mapCollections().find((item) => item.slug === slug)
  return collection?.resources || []
}

function resourcesForEducationTier(categorySlug, tierSlug) {
  const category = educationCategories().find((item) => item.slug === categorySlug)
  const tier = category?.tiers?.find((item) => item.slug === tierSlug)
  return tier?.resources || []
}

function resourcesForEducationResource(categorySlug, resourceId) {
  const category = educationCategories().find((item) => item.slug === categorySlug)
  return (category?.tiers || [])
    .flatMap((tier) => tier.resources || [])
    .filter((resource) => resource.id === resourceId)
}

async function queueRoachSpeechPackDownload(body) {
  const packID = safeFileName(body.packID || body.pack || 'roachspeech-pack', 'roachspeech-pack')
  const kind = safeFileName(body.kind || 'roachVoice', 'roachVoice')
  const destination = path.join(storageRoot, 'RoachSpeech', 'ModelPacks', '.downloads', kind, packID)
  const job = await queueResolvedDownload(body.url, destination, 'roachspeech-pack', {
    afterDownload: (downloadJob) => installRoachSpeechPackArchive(downloadJob, packID, kind),
  })
  upsertRoachSpeechPackRegistry({
    packID,
    kind,
    url: job?.url || body.url,
    descriptorUrl: job?.descriptorUrl || null,
    expectedSha256: job?.expectedSha256 || null,
    status: job ? 'queued' : 'idle',
    filepath: job?.filepath || null,
    installPath: job?.installPath || null,
  })
  return { job, packID, kind }
}

function appStoreInstallResponse(action, jobs, message, extra = {}) {
  const normalizedJobs = Array.isArray(jobs) ? jobs.filter(Boolean) : [jobs].filter(Boolean)
  return {
    success: normalizedJobs.length > 0 || extra.success === true,
    ok: normalizedJobs.length > 0 || extra.success === true,
    action,
    message,
    jobId: normalizedJobs[0]?.jobId || null,
    jobIds: normalizedJobs.map((job) => job.jobId),
    queued: normalizedJobs.length,
    ...extra,
  }
}

async function handleCompanionInstall(body) {
  const action = String(body.action || body.type || '').trim()
  if (!action) {
    throw new NativeApiRequestError('App Store install action is missing.', 400)
  }

  switch (action) {
  case 'base-map-assets':
    mkdirSync(path.join(storageRoot, 'maps', 'pmtiles'), { recursive: true })
    mkdirSync(path.join(storageRoot, 'maps', 'basemaps-assets'), { recursive: true })
    return appStoreInstallResponse(action, [], 'Base atlas folders are ready.', { success: true })

  case 'map-collection': {
    const slug = String(body.slug || '').trim()
    if (!slug) throw new NativeApiRequestError('Map collection slug is missing.', 400)
    const jobs = (await Promise.all(resourcesForMapCollection(slug).map((resource) =>
      queueResolvedDownload(resource.descriptorUrl || resource.url, path.join(storageRoot, 'maps', 'pmtiles'), 'pmtiles')
    ))).filter(Boolean)
    return appStoreInstallResponse(action, jobs, `${jobs.length} map download${jobs.length === 1 ? '' : 's'} queued.`, { slug })
  }

  case 'education-tier': {
    const categorySlug = String(body.categorySlug || body.category || '').trim()
    const tierSlug = String(body.tierSlug || body.tier || '').trim()
    if (!categorySlug || !tierSlug) {
      throw new NativeApiRequestError('Education tier install needs category and tier.', 400)
    }
    const jobs = (await Promise.all(resourcesForEducationTier(categorySlug, tierSlug).map((resource) =>
      queueResolvedDownload(resource.descriptorUrl || resource.url, path.join(storageRoot, 'zim'), 'zim')
    ))).filter(Boolean)
    return appStoreInstallResponse(action, jobs, `${jobs.length} knowledge download${jobs.length === 1 ? '' : 's'} queued.`, {
      categorySlug,
      tierSlug,
    })
  }

  case 'education-resource': {
    const categorySlug = String(body.categorySlug || body.category || '').trim()
    const resourceId = String(body.resourceId || body.resource || '').trim()
    if (!categorySlug || !resourceId) {
      throw new NativeApiRequestError('Education resource install needs category and resource.', 400)
    }
    const jobs = (await Promise.all(resourcesForEducationResource(categorySlug, resourceId).map((resource) =>
      queueResolvedDownload(resource.descriptorUrl || resource.url, path.join(storageRoot, 'zim'), 'zim')
    ))).filter(Boolean)
    return appStoreInstallResponse(action, jobs, `${jobs.length} knowledge download${jobs.length === 1 ? '' : 's'} queued.`, {
      categorySlug,
      resourceId,
    })
  }

  case 'direct-download': {
    const rawUrl = body.url || body.mirrorUrl || body.sourceUrl
    const filetype = String(body.filetype || body.resourceType || '').toLowerCase()
    if (!rawUrl) throw new NativeApiRequestError('Direct App Store download URL is missing.', 400)
    if (['map', 'pmtiles'].includes(filetype)) {
      const job = await queueResolvedDownload(rawUrl, path.join(storageRoot, 'maps', 'pmtiles'), 'pmtiles')
      return appStoreInstallResponse(action, job, job ? 'Map download queued.' : 'No map URL provided.', { filetype })
    }
    if (['zim', 'knowledge', 'education'].includes(filetype)) {
      const job = await queueResolvedDownload(rawUrl, path.join(storageRoot, 'zim'), 'zim')
      return appStoreInstallResponse(action, job, job ? 'Knowledge pack queued.' : 'No ZIM URL provided.', { filetype })
    }
    throw new NativeApiRequestError(`Unsupported direct App Store download type: ${filetype || 'unknown'}.`, 400)
  }

  case 'wikipedia-option': {
    const optionId = String(body.optionId || body.option || '').trim()
    const option = wikipediaOptions().find((item) => item.id === optionId)
    mkdirSync(path.join(storageRoot, 'zim'), { recursive: true })
    if (!option || option.id === 'none' || !option.url) {
      writeFileSync(wikipediaSelectionPath(), JSON.stringify({ optionId: optionId || 'none', status: 'skipped', filename: null, url: null }, null, 2))
      return appStoreInstallResponse(action, [], 'Wikipedia install skipped.', { success: true, optionId: optionId || 'none' })
    }
    const descriptorUrl = option.url ? descriptorUrlForSource(option.url, 'content/wikipedia') : null
    const job = await queueResolvedDownload(descriptorUrl || option.url, path.join(storageRoot, 'zim'), 'zim')
    const selection = {
      optionId: option.id,
      status: job ? 'queued' : 'idle',
      filename: option.url ? fileNameForUrl(option.url, `${option.id}.zim`) : null,
      url: option.url,
      descriptorUrl,
    }
    writeFileSync(wikipediaSelectionPath(), JSON.stringify(selection, null, 2))
    return appStoreInstallResponse(action, job, `${option.name} queued.`, { optionId: option.id })
  }

  case 'roachclaw-model': {
    const model = String(body.model || '').trim()
    if (!model) throw new NativeApiRequestError('RoachClaw model name is missing.', 400)
    await pullModel(model)
    return appStoreInstallResponse(action, [], `${model} model pull queued.`, { success: true, model })
  }

  case 'roachspeech-pack':
  case 'roachvoice-pack': {
    if (!body.url) throw new NativeApiRequestError('RoachSpeech pack URL is missing.', 400)
    const { job, packID, kind } = await queueRoachSpeechPackDownload(body)
    return appStoreInstallResponse(
      action,
      job,
      job
        ? `${packID} RoachSpeech pack queued. It will unpack into the local model shelf when the download finishes.`
        : 'No RoachSpeech pack URL provided.',
      { packID, kind }
    )
  }

  default:
    throw new NativeApiRequestError(`Unsupported App Store install action: ${action}.`, 400)
  }
}

async function handleChat(body) {
  await ensureOllama()
  try {
    return await fetchJson(new URL('/api/chat', ollamaBaseUrl).toString(), {
      method: 'POST',
      body: JSON.stringify(body),
      timeout: 120_000,
    })
  } catch (error) {
    return {
      message: {
        role: 'assistant',
        content: `Local model route is not ready: ${error.message}`,
      },
    }
  }
}

async function pullModel(model) {
  await ensureOllama()
  if (!model) return
  installedModelsCache.invalidate(ollamaBaseUrl)
  fetchJson(new URL('/api/pull', ollamaBaseUrl).toString(), {
    method: 'POST',
    body: JSON.stringify({ name: model, stream: false }),
    timeout: 600_000,
  })
    .finally(() => installedModelsCache.invalidate(ollamaBaseUrl))
    .catch((error) => log(`model pull failed: ${error.message}`))
}

async function route(request, response) {
  // Same CSRF / DNS-rebinding stance as the Swift runtime: no rebound Host,
  // no cross-site Origin (see roachnet_loopback_guard).
  const rejection = loopbackRequestRejection(request)
  if (rejection) return sendJson(response, rejection.statusCode, { error: rejection.error })
  const url = new URL(request.url, 'http://127.0.0.1')
  const method = request.method || 'GET'
  const pathname = url.pathname

  if (method === 'GET' && pathname === '/api/health') return sendJson(response, 200, { status: 'ok' })
  if (method === 'GET' && pathname === '/api/system/internet-status') {
    const online = await lookup('github.com').then(() => true).catch(() => false)
    return sendJson(response, 200, online)
  }
  if (method === 'GET' && pathname === '/api/system/info') return sendJson(response, 200, systemInfo())
  if (method === 'GET' && pathname === '/api/system/services') return sendJson(response, 200, await systemServices())
  if (method === 'GET' && pathname === '/api/system/ai/providers') {
    const providers = {
      ollama: await providerStatus('ollama', ollamaBaseUrl),
      openclaw: await providerStatus('openclaw', openClawBaseUrl),
    }
    return sendJson(response, 200, { providers, cloudProviders: roachClawPublicCloudProviderKeysState() })
  }
  if (method === 'GET' && pathname === '/api/system/latest-version') {
    return sendJson(response, 200, await latestVersionResponse(url.searchParams.get('force') === '1'))
  }
  if (method === 'GET' && pathname === '/api/system/update/status') {
    return sendJson(response, 200, systemUpdateStatus)
  }
  if (method === 'POST' && pathname === '/api/system/update') {
    return sendJson(response, 202, await requestUpdateDownload(true))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/status') return sendJson(response, 200, await roachClawStatus())
  if (method === 'GET' && pathname === '/api/roachclaw/diagnostics/services') {
    const status = await roachClawStatus()
    return sendJson(response, 200, status.operations.serviceHealth.report)
  }
  if (method === 'GET' && pathname.startsWith('/api/roachclaw/operations')) {
    const status = await roachClawStatus()
    const section = pathname.split('/').at(-1)
    if (section && section !== 'operations' && Object.hasOwn(status.operations, section)) {
      return sendJson(response, 200, status.operations[section])
    }
    return sendJson(response, 200, status.operations)
  }
  if (method === 'GET' && pathname === '/api/roachclaw/workspace/browse') {
    return sendJson(response, 200, browseRoachClawWorkspace(url.searchParams.get('path') || ''))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/user-time') {
    return sendJson(response, 200, roachClawUserTimeState())
  }
  if (method === 'POST' && pathname === '/api/roachclaw/user-time') {
    return sendJson(response, 200, upsertRoachClawUserTime(await readRequestJson(request)))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/cookbook/schedules') {
    return sendJson(response, 200, roachClawCookbookServeState())
  }
  if (method === 'POST' && pathname === '/api/roachclaw/cookbook/schedules') {
    return sendJson(response, 200, upsertRoachClawCookbookServeSchedule(await readRequestJson(request)))
  }
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/cookbook/schedules/')) {
    return sendJson(response, 200, deleteRoachClawCollectionItem('cookbook-serve-schedules.json', 'schedules', decodeURIComponent(pathname.split('/').at(-1))))
  }
  if (method === 'POST' && pathname === '/api/roachclaw/cookbook/progress-signal') {
    return sendJson(response, 200, computeRoachClawCookbookProgressSignal(await readRequestJson(request)))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/scoped-tools/capabilities') {
    return sendJson(response, 200, roachClawScopedToolBridgeState())
  }
  if (method === 'GET' && pathname === '/api/roachclaw/security/tls-overrides') {
    return sendJson(response, 200, roachClawTlsOverridesState())
  }
  if (method === 'POST' && pathname === '/api/roachclaw/security/tls-overrides') {
    return sendJson(response, 200, upsertRoachClawTlsOverride(await readRequestJson(request)))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/security/upload-limits') {
    return sendJson(response, 200, roachClawUploadLimitsState())
  }
  if (method === 'GET' && pathname === '/api/roachclaw/migration-document-tools') {
    return sendJson(response, 200, roachClawMigrationDocumentToolsState())
  }
  if (method === 'GET' && pathname === '/api/roachclaw/memory-provider') {
    return sendJson(response, 200, roachClawMemoryProviderState())
  }
  if (method === 'POST' && pathname === '/api/roachclaw/memory-provider') {
    return sendJson(response, 200, upsertRoachClawMemoryProvider(await readRequestJson(request)))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/provider-oauth') {
    return sendJson(response, 200, roachClawProviderOAuthState())
  }
  if (method === 'POST' && pathname === '/api/roachclaw/provider-oauth') {
    return sendJson(response, 200, upsertRoachClawProviderOAuthFlow(await readRequestJson(request)))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/embedding-lanes') {
    return sendJson(response, 200, roachClawEmbeddingLanesState())
  }
  if (method === 'POST' && pathname === '/api/roachclaw/embedding-lanes') {
    return sendJson(response, 200, upsertRoachClawEmbeddingLane(await readRequestJson(request)))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/tool-policy') {
    return sendJson(response, 200, roachClawToolPolicyState())
  }
  if (method === 'POST' && pathname === '/api/roachclaw/tool-policy') {
    return sendJson(response, 200, upsertRoachClawToolPolicy(await readRequestJson(request)))
  }
  if (method === 'POST' && pathname === '/api/roachclaw/tool-policy/evaluate') {
    return sendJson(response, 200, roachClawToolPolicyState(await readRequestJson(request)))
  }
  if (method === 'GET' && pathname === '/api/roachclaw/agent/status') {
    const status = await roachClawStatus()
    return sendJson(response, 200, status.agent)
  }
  if (method === 'POST' && pathname === '/api/roachclaw/agent/run') {
    const status = await roachClawStatus()
    return sendJson(response, 200, createRoachClawAgentRun(await readRequestJson(request), status.agent))
  }
  if (method === 'POST' && pathname === '/api/roachclaw/apply') {
    const body = await readRequestJson(request)
    pullModel(body.model || defaultModel)
    return sendJson(response, 200, { success: true, ok: true, message: 'Local model pull queued.' })
  }
  if (method === 'POST' && pathname === '/api/system/services/install') {
    const body = await readRequestJson(request)
    if (body.service_name === 'roachnet_ollama') {
      await ensureOllama()
      return sendJson(response, 200, { success: true, ok: true, message: 'Ollama start requested.' })
    }
    return sendJson(response, 200, { success: true, ok: true, message: 'Native service registered. Container install is not required for this lane.' })
  }
  if (method === 'POST' && pathname === '/api/system/services/affect') {
    const body = await readRequestJson(request)
    if (body.service_name === 'roachnet_ollama' && body.action === 'start') {
      await ensureOllama()
    }
    return sendJson(response, 200, { success: true, ok: true, message: `${body.action || 'Service'} request recorded.` })
  }
  if (method === 'GET' && pathname === '/api/ollama/installed-models') return sendJson(response, 200, await installedModels())
  if (method === 'POST' && pathname === '/api/ollama/chat') return sendJson(response, 200, await handleChat(await readRequestJson(request)))
  if (method === 'GET' && pathname === '/api/openclaw/skills/installed') {
    return sendJson(response, 200, { workspacePath: process.env.OPENCLAW_WORKSPACE_PATH || path.join(storageRoot, 'RoachClaw'), skills: [] })
  }
  if (method === 'GET' && pathname === '/api/rag/files') {
    return sendJson(response, 200, { files: listVaultKnowledgeFiles(path.join(storageRoot, 'Vault')) })
  }
  if (method === 'GET' && pathname === '/api/maps/curated-collections') return sendJson(response, 200, mapCollections())
  if (method === 'POST' && pathname === '/api/maps/download-base-assets') {
    mkdirSync(path.join(storageRoot, 'maps', 'pmtiles'), { recursive: true })
    mkdirSync(path.join(storageRoot, 'maps', 'basemaps-assets'), { recursive: true })
    return sendJson(response, 200, { success: true, ok: true, message: 'Base atlas folders are ready.' })
  }
  if (method === 'POST' && pathname === '/api/maps/download-collection') {
    const body = await readRequestJson(request)
    const jobs = (await Promise.all(resourcesForMapCollection(body.slug).map((resource) =>
      queueResolvedDownload(resource.descriptorUrl || resource.url, path.join(storageRoot, 'maps', 'pmtiles'), 'pmtiles')
    ))).filter(Boolean)
    return sendJson(response, 200, { success: true, ok: true, message: `${jobs.length} map download${jobs.length === 1 ? '' : 's'} queued.` })
  }
  if (method === 'POST' && pathname === '/api/maps/download-remote') {
    const body = await readRequestJson(request)
    const job = await queueResolvedDownload(body.url, path.join(storageRoot, 'maps', 'pmtiles'), 'pmtiles')
    return sendJson(response, 200, { success: Boolean(job), ok: Boolean(job), message: job ? 'Remote map download queued.' : 'No map URL provided.' })
  }
  if (method === 'GET' && pathname === '/api/zim/curated-categories') return sendJson(response, 200, educationCategories())
  if (method === 'GET' && pathname === '/api/zim/wikipedia') return sendJson(response, 200, wikipediaState())
  if (method === 'POST' && pathname === '/api/zim/download-category-tier') {
    const body = await readRequestJson(request)
    const jobs = (await Promise.all(resourcesForEducationTier(body.categorySlug, body.tierSlug).map((resource) =>
      queueResolvedDownload(resource.descriptorUrl || resource.url, path.join(storageRoot, 'zim'), 'zim')
    ))).filter(Boolean)
    return sendJson(response, 200, { success: true, ok: true, message: `${jobs.length} knowledge download${jobs.length === 1 ? '' : 's'} queued.` })
  }
  if (method === 'POST' && pathname === '/api/zim/download-category-resource') {
    const body = await readRequestJson(request)
    const jobs = (await Promise.all(resourcesForEducationResource(body.categorySlug, body.resourceId).map((resource) =>
      queueResolvedDownload(resource.descriptorUrl || resource.url, path.join(storageRoot, 'zim'), 'zim')
    ))).filter(Boolean)
    return sendJson(response, 200, { success: true, ok: true, message: `${jobs.length} knowledge download${jobs.length === 1 ? '' : 's'} queued.` })
  }
  if (method === 'POST' && pathname === '/api/zim/download-remote') {
    const body = await readRequestJson(request)
    const job = await queueResolvedDownload(body.url, path.join(storageRoot, 'zim'), 'zim')
    return sendJson(response, 200, { success: Boolean(job), ok: Boolean(job), message: job ? 'Remote knowledge pack queued.' : 'No ZIM URL provided.' })
  }
  if (method === 'POST' && pathname === '/api/zim/wikipedia/select') {
    const body = await readRequestJson(request)
    const option = wikipediaOptions().find((item) => item.id === body.optionId)
    mkdirSync(path.join(storageRoot, 'zim'), { recursive: true })
    if (!option || option.id === 'none' || !option.url) {
      writeFileSync(wikipediaSelectionPath(), JSON.stringify({ optionId: body.optionId || 'none', status: 'skipped', filename: null, url: null }, null, 2))
      return sendJson(response, 200, { success: true, ok: true, message: 'Wikipedia install skipped.' })
    }
    const descriptorUrl = option.url ? descriptorUrlForSource(option.url, 'content/wikipedia') : null
    const job = await queueResolvedDownload(descriptorUrl || option.url, path.join(storageRoot, 'zim'), 'zim')
    const selection = {
      optionId: option.id,
      status: job ? 'queued' : 'idle',
      filename: option.url ? fileNameForUrl(option.url, `${option.id}.zim`) : null,
      url: option.url,
      descriptorUrl,
    }
    writeFileSync(wikipediaSelectionPath(), JSON.stringify(selection, null, 2))
    return sendJson(response, 200, { success: true, ok: true, message: `${option.name} queued.` })
  }
  if (method === 'POST' && pathname === '/api/roachspeech/model-packs/download') {
    const body = await readRequestJson(request)
    const { job, packID, kind } = await queueRoachSpeechPackDownload(body)
    return sendJson(response, 200, {
      success: Boolean(job),
      ok: Boolean(job),
      message: job
        ? `${packID} RoachSpeech pack queued. It will unpack into the local model shelf when the download finishes.`
        : 'No RoachSpeech pack URL provided.',
      packID,
      kind,
      jobId: job?.jobId || null,
    })
  }
  if (method === 'GET' && pathname === '/api/roachspeech/model-packs') {
    const packsRoot = modelPacksRootPath()
    const entries = existsSync(packsRoot)
      ? readdirSync(packsRoot, { withFileTypes: true })
          .filter((entry) => entry.isDirectory() && !entry.name.startsWith('.'))
          .map((entry) => {
            const root = path.join(packsRoot, entry.name)
            const manifestPath = path.join(root, 'RoachSpeechPack.json')
            const manifest = readJsonFile([manifestPath], null)
            return {
              packID: entry.name,
              root,
              installed: Boolean(manifest),
              manifest,
            }
          })
      : []
    return sendJson(response, 200, {
      success: true,
      ok: true,
      modelPacksRoot: packsRoot,
      packs: entries,
      registry: readRoachSpeechPackRegistry(),
    })
  }
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/contacts/')) return sendJson(response, 200, deleteRoachClawCollectionItem('contacts.json', 'contacts', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/contacts') return sendJson(response, 200, roachClawContactsState())
  if (method === 'POST' && pathname === '/api/roachclaw/contacts') return sendJson(response, 200, upsertRoachClawContact(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/tasks/')) return sendJson(response, 200, deleteRoachClawCollectionItem('tasks.json', 'tasks', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/tasks') return sendJson(response, 200, roachClawTaskState())
  if (method === 'POST' && pathname === '/api/roachclaw/tasks') return sendJson(response, 200, upsertRoachClawTask(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/calendar/')) return sendJson(response, 200, deleteRoachClawCollectionItem('calendar.json', 'events', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/calendar') return sendJson(response, 200, roachClawCalendarState())
  if (method === 'POST' && pathname === '/api/roachclaw/calendar') return sendJson(response, 200, upsertRoachClawCalendarEvent(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/reports/')) return sendJson(response, 200, deleteRoachClawCollectionItem('reports.json', 'reports', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/reports') return sendJson(response, 200, roachClawReportsState())
  if (method === 'POST' && pathname === '/api/roachclaw/reports') return sendJson(response, 200, upsertRoachClawReport(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/memories/')) return sendJson(response, 200, deleteRoachClawCollectionItem('memories.json', 'memories', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/memories') return sendJson(response, 200, roachClawMemoriesState())
  if (method === 'POST' && pathname === '/api/roachclaw/memories') return sendJson(response, 200, upsertRoachClawMemory(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/skills/')) return sendJson(response, 200, deleteRoachClawCollectionItem('skills.json', 'skills', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/skills') return sendJson(response, 200, roachClawSkillsState())
  if (method === 'POST' && pathname === '/api/roachclaw/skills') return sendJson(response, 200, upsertRoachClawSkill(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/editor-drafts/')) return sendJson(response, 200, deleteRoachClawCollectionItem('editor-drafts.json', 'drafts', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/editor-drafts') return sendJson(response, 200, roachClawEditorDraftsState())
  if (method === 'POST' && pathname === '/api/roachclaw/editor-drafts') return sendJson(response, 200, upsertRoachClawEditorDraft(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/search-cache/')) return sendJson(response, 200, deleteRoachClawCollectionItem('search-cache.json', 'entries', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/search-cache') return sendJson(response, 200, roachClawSearchCacheState())
  if (method === 'POST' && pathname === '/api/roachclaw/search-cache') return sendJson(response, 200, upsertRoachClawSearchCacheEntry(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/gallery/')) return sendJson(response, 200, deleteRoachClawCollectionItem('gallery.json', 'assets', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/gallery') return sendJson(response, 200, roachClawGalleryState())
  if (method === 'POST' && pathname === '/api/roachclaw/gallery') return sendJson(response, 200, upsertRoachClawGalleryAsset(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/webhooks/')) return sendJson(response, 200, deleteRoachClawCollectionItem('webhooks.json', 'webhooks', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/webhooks') return sendJson(response, 200, roachClawWebhooksState())
  if (method === 'POST' && pathname === '/api/roachclaw/webhooks') return sendJson(response, 200, upsertRoachClawWebhook(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/agent-runs/')) return sendJson(response, 200, deleteRoachClawCollectionItem('agent-runs.json', 'runs', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/agent-runs') return sendJson(response, 200, roachClawAgentRunsState())
  if (method === 'POST' && pathname === '/api/roachclaw/agent-runs') return sendJson(response, 200, upsertRoachClawAgentRun(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/context-compactions/')) return sendJson(response, 200, deleteRoachClawCollectionItem('context-compactions.json', 'compactions', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/context-compactions') return sendJson(response, 200, roachClawContextCompactionsState())
  if (method === 'POST' && pathname === '/api/roachclaw/context-compactions') return sendJson(response, 200, upsertRoachClawContextCompaction(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/tool-index/')) return sendJson(response, 200, deleteRoachClawCollectionItem('tool-index.json', 'tools', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/tool-index') return sendJson(response, 200, roachClawToolIndexState())
  if (method === 'POST' && pathname === '/api/roachclaw/tool-index') return sendJson(response, 200, upsertRoachClawToolIndexEntry(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/events/')) return sendJson(response, 200, deleteRoachClawCollectionItem('events.json', 'events', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/events') return sendJson(response, 200, roachClawEventsState())
  if (method === 'POST' && pathname === '/api/roachclaw/events') return sendJson(response, 200, upsertRoachClawEvent(await readRequestJson(request)))
  if (method === 'GET' && pathname === '/api/roachclaw/mail') return sendJson(response, 200, roachClawMailState())
  if (method === 'POST' && pathname === '/api/roachclaw/mail/messages') return sendJson(response, 200, upsertRoachClawMailMessage(await readRequestJson(request)))
  if (method === 'POST' && pathname === '/api/roachclaw/mail/drafts') return sendJson(response, 200, upsertRoachClawMailDraft(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/mail/messages/')) return sendJson(response, 200, deleteRoachClawMailItem('messages', pathname.split('/').at(-1)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/mail/drafts/')) return sendJson(response, 200, deleteRoachClawMailItem('drafts', pathname.split('/').at(-1)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/presets/')) return sendJson(response, 200, deleteRoachClawCollectionItem('presets.json', 'templates', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/presets') return sendJson(response, 200, roachClawPresetsState())
  if (method === 'POST' && pathname === '/api/roachclaw/presets') return sendJson(response, 200, upsertRoachClawPreset(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/signatures/')) return sendJson(response, 200, deleteRoachClawCollectionItem('signatures.json', 'signatures', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/signatures') return sendJson(response, 200, roachClawSignaturesState())
  if (method === 'POST' && pathname === '/api/roachclaw/signatures') return sendJson(response, 200, upsertRoachClawSignature(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/tokens/')) return sendJson(response, 200, deleteRoachClawApiToken(pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/tokens') return sendJson(response, 200, roachClawPublicApiTokensState())
  if (method === 'POST' && pathname === '/api/roachclaw/tokens') return sendJson(response, 200, createRoachClawApiToken(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/cloud-providers/')) return sendJson(response, 200, deleteRoachClawCloudProviderKey(pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/cloud-providers') return sendJson(response, 200, roachClawPublicCloudProviderKeysState())
  if (method === 'POST' && pathname === '/api/roachclaw/cloud-providers') return sendJson(response, 200, upsertRoachClawCloudProviderKey(await readRequestJson(request)))
  if (method === 'DELETE' && pathname.startsWith('/api/roachclaw/backups/')) return sendJson(response, 200, deleteRoachClawCollectionItem('backups.json', 'snapshots', pathname.split('/').at(-1)))
  if (method === 'GET' && pathname === '/api/roachclaw/backups') return sendJson(response, 200, roachClawBackupsState())
  if (method === 'POST' && pathname === '/api/roachclaw/backups') return sendJson(response, 200, createRoachClawBackup(await readRequestJson(request)))
  if (method === 'GET' && pathname === '/api/roachclaw/export') return sendJson(response, 200, roachClawExportPayload())
  if (method === 'GET' && pathname === '/api/site-archives') return sendJson(response, 200, { archives: siteArchives() })
  if (method === 'GET' && pathname === '/api/companion/bootstrap') return sendJson(response, 200, await companionBootstrapState())
  if (method === 'GET' && pathname === '/api/companion/runtime') return sendJson(response, 200, await companionRuntimeState())
  if (method === 'GET' && pathname === '/api/companion/vault') return sendJson(response, 200, companionVaultState())
  if (method === 'GET' && pathname === '/api/companion/account') return sendJson(response, 200, accountState())
  if (method === 'GET' && pathname === '/api/companion/roachtail') {
    return sendJson(response, 200, roachTailState({ hideJoinCode: isPeerRoachTailRequest(request) }))
  }
  if (method === 'POST' && pathname === '/api/companion/roachtail/pair') {
    return sendJson(response, 200, pairRoachTailPeer(await readRequestJson(request)))
  }
  if (method === 'POST' && pathname === '/api/companion/roachtail/affect') {
    const body = await readRequestJson(request)
    return sendJson(response, 200, mutateRoachTailState(body.action, body, request))
  }
  if (method === 'GET' && pathname === '/api/companion/roachsync') return sendJson(response, 200, roachSyncState())
  if (method === 'POST' && pathname === '/api/companion/install') {
    return sendJson(response, 200, await handleCompanionInstall(await readRequestJson(request)))
  }
  if (method === 'POST' && pathname.startsWith('/api/companion/')) return sendJson(response, 200, { success: true, ok: true, message: 'Native companion action recorded.' })
  if (method === 'DELETE' && pathname.startsWith('/api/downloads/jobs/')) {
    const jobId = decodeURIComponent(pathname.split('/').at(-1) || '')
    const job = downloadJobs.find((item) => item.jobId === jobId)
    if (job && ['queued', 'downloading'].includes(job.status)) {
      job.status = 'cancelled'
      job.failedReason = null
      job.updatedAt = new Date().toISOString()
      if (typeof job.abort === 'function') {
        job.abort()
      }
      rmSync(job.partialFilepath, { force: true })
    }
    downloadJobs = downloadJobs.filter((job) => job.jobId !== jobId)
    return sendJson(response, 200, { success: true, ok: true, cancelled: Boolean(job) })
  }
  if (method === 'GET' && pathname === '/api/downloads/jobs') return sendJson(response, 200, downloadJobs)
  if (method === 'GET' && pathname === '/api/benchmark/status') return sendJson(response, 200, benchmarkStatus)
  if (method === 'POST' && pathname === '/api/benchmark/run') {
    const body = await readRequestJson(request)
    benchmarkStatus = { status: 'starting', benchmarkId: randomUUID() }
    setTimeout(() => {
      benchmarkStatus = { status: 'idle', benchmarkId: null }
    }, 2_000)
    return sendJson(response, 201, {
      success: true,
      job_id: benchmarkStatus.benchmarkId,
      benchmark_id: benchmarkStatus.benchmarkId,
      message: `${body.benchmark_type || 'system'} benchmark started`,
    })
  }

  return sendJson(response, 404, { error: `No native endpoint for ${method} ${pathname}` })
}

function wantsCompanionRuntime() {
  const mode = process.env.ROACHNET_COMPANION_ENABLED?.trim()
  if (mode) {
    return !['0', 'false', 'no', 'off'].includes(mode.toLowerCase())
  }
  return Boolean(process.env.ROACHNET_COMPANION_TOKEN?.trim())
}

function companionLocalUrl() {
  if (!wantsCompanionRuntime()) {
    return null
  }
  const host = process.env.ROACHNET_COMPANION_HOST?.trim() || '127.0.0.1'
  const displayHost = host === '0.0.0.0' || host === '::' ? '127.0.0.1' : host
  const port = process.env.ROACHNET_COMPANION_PORT?.trim() || '38111'
  return `http://${displayHost.includes(':') ? `[${displayHost}]` : displayHost}:${port}`
}

function isPeerRoachTailRequest(request) {
  return request?.headers?.['x-roachtail-auth-kind']?.trim?.().toLowerCase() === 'peer'
}

async function waitForCompanion(localUrl, timeoutMs = 15_000) {
  if (!localUrl) {
    return false
  }
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const response = await fetch(new URL('/health', localUrl), { headers: { Accept: 'application/json' } })
      if (response.ok) {
        return true
      }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
  return false
}

async function maybeStartCompanion(baseUrl) {
  if (!wantsCompanionRuntime()) {
    return { localUrl: null, advertisedUrl: null, pid: null }
  }

  const token = process.env.ROACHNET_COMPANION_TOKEN?.trim()
  if (!token) {
    await log('companion requested without token; skipping companion bridge')
    return { localUrl: null, advertisedUrl: null, pid: null }
  }

  const entrypoint = path.join(repoRoot, 'scripts', 'roachnet-companion-server.mjs')
  if (!existsSync(entrypoint)) {
    await log('companion entrypoint missing; skipping companion bridge')
    return { localUrl: null, advertisedUrl: null, pid: null }
  }

  const localUrl = companionLocalUrl()
  const advertisedUrl = process.env.ROACHNET_COMPANION_ADVERTISED_URL?.trim() || localUrl
  companionProcess = spawn(process.execPath, [entrypoint], {
    cwd: repoRoot,
    detached: false,
    stdio: 'ignore',
    env: {
      ...process.env,
      ROACHNET_COMPANION_ENABLED: '1',
      ROACHNET_COMPANION_HOST: process.env.ROACHNET_COMPANION_HOST?.trim() || '127.0.0.1',
      ROACHNET_COMPANION_PORT: process.env.ROACHNET_COMPANION_PORT?.trim() || '38111',
      ROACHNET_COMPANION_TOKEN: token,
      ROACHNET_COMPANION_ADVERTISED_URL: advertisedUrl || '',
      ROACHNET_COMPANION_TARGET_URL: baseUrl,
    },
  })
  await log(`started companion pid=${companionProcess.pid} url=${localUrl}`)
  await waitForCompanion(localUrl)
  return { localUrl, advertisedUrl, pid: companionProcess.pid }
}

function writeRuntimeInfo({ baseUrl, companion }) {
  const info = {
    pid: process.pid,
    healthUrl: `${baseUrl}/api/health`,
    webUrl: baseUrl,
    companionUrl: companion.localUrl,
    companionAdvertisedUrl: companion.advertisedUrl,
    target: 'native-api',
    repoRoot,
    logPath,
  }
  writeFileSync(
    statePath,
    JSON.stringify(
      {
        pid: process.pid,
        companionPid: companion.pid,
        port: new URL(baseUrl).port,
        baseUrl,
        startedAt: new Date().toISOString(),
      },
      null,
      2
    )
  )
  writeFileSync(
    processInfoPath,
    JSON.stringify(
      {
        target: 'native-api',
        companionUrl: companion.localUrl,
        companionAdvertisedUrl: companion.advertisedUrl,
        processes: [
          { name: 'native-api', pid: process.pid, port: Number(new URL(baseUrl).port), healthUrl: info.healthUrl },
          ...(companion.pid ? [{ name: 'companion', pid: companion.pid, url: companion.localUrl }] : []),
        ],
        updatedAt: new Date().toISOString(),
      },
      null,
      2
    )
  )
  if (process.env.ROACHNET_SERVER_INFO_FILE) {
    mkdirSync(path.dirname(process.env.ROACHNET_SERVER_INFO_FILE), { recursive: true })
    writeFileSync(process.env.ROACHNET_SERVER_INFO_FILE, JSON.stringify(info, null, 2))
  }
}

function listenServer(server, port, host) {
  return new Promise((resolve, reject) => {
    const handleError = (error) => {
      reject(error)
    }

    server.once('error', handleError)
    server.listen(port, host, () => {
      server.off('error', handleError)
      resolve(server.address())
    })
  })
}

async function main() {
  await stopExistingRuntime()
  const server = http.createServer((request, response) => {
    route(request, response).catch((error) => {
      log(`request failed: ${error.stack || error.message}`)
      sendError(response, error, 500)
    })
  })

  const listenPort = Number(process.env.PORT || '0')
  const listenHost = normalizeLoopbackHost(process.env.HOST)

  const address = await listenServer(server, listenPort, listenHost)
  const port = typeof address === 'object' && address ? address.port : listenPort
  const baseUrl = `http://127.0.0.1:${port}`
  let companion = { localUrl: null, advertisedUrl: null, pid: null }
  try {
    companion = await maybeStartCompanion(baseUrl)
  } catch (error) {
    await log(`companion start failed: ${error.stack || error.message}`)
  }
  writeRuntimeInfo({ baseUrl, companion })
  await log(`native api listening on ${baseUrl}`)
  ensureOllama().catch((error) => log(`ollama warmup failed: ${error.stack || error.message}`))

  const shutdown = () => {
    cleanupRuntimeStateFiles()
    if (companionProcess && companionProcess.exitCode === null) {
      companionProcess.kill('SIGTERM')
    }
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 3_000).unref()
  }

  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
}

main().catch(async (error) => {
  await log(`fatal: ${error.stack || error.message}`)
  process.exit(1)
})
