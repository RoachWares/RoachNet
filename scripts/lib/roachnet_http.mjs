import { createWriteStream, renameSync, rmSync } from 'node:fs'
import http from 'node:http'
import https from 'node:https'
import { Transform } from 'node:stream'
import { pipeline } from 'node:stream/promises'

const DEFAULT_TIMEOUT_MS = 30_000
const DEFAULT_MAX_REDIRECTS = 5
const DEFAULT_MAX_RESPONSE_BYTES = 16 * 1024 * 1024
const DEFAULT_MAX_DOWNLOAD_BYTES = 8 * 1024 ** 3

function positiveInteger(value, fallback) {
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback
}

function transportFor(url) {
  if (url.protocol === 'http:') {
    return http
  }
  if (url.protocol === 'https:') {
    return https
  }
  throw new Error(`Unsupported HTTP protocol: ${url.protocol}`)
}

function resolveRedirectURL(location, currentUrl) {
  if (!location) {
    return null
  }
  return new URL(location, currentUrl)
}

function bodyBufferFor(body) {
  if (body === undefined || body === null) {
    return null
  }
  return Buffer.isBuffer(body) ? body : Buffer.from(String(body))
}

export class RoachNetHTTPError extends Error {
  constructor(message, { code, statusCode } = {}) {
    super(message)
    this.code = code
    this.statusCode = statusCode
  }
}

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '::1'])

// Smoke and audit scripts talk to the runtime on this Mac and nothing else.
function assertLocalRuntimeURL(url) {
  if (!['http:', 'https:'].includes(url.protocol)) {
    throw new Error('The local runtime URL must use http or https.')
  }
  if (url.username || url.password) {
    throw new Error('The local runtime URL must not include credentials.')
  }
  const host = url.hostname.replace(/^\[|\]$/g, '').replace(/\.$/, '').toLowerCase()
  if (!LOOPBACK_HOSTS.has(host)) {
    throw new Error('The local runtime URL must point at the local desktop runtime.')
  }
}

export async function requestLocalRuntimeHttp(rawUrl, options = {}) {
  const url = new URL(rawUrl)
  assertLocalRuntimeURL(url)
  return requestHttp(url, {
    ...options,
    maxRedirects: 0,
  })
}

export async function requestHttp(rawUrl, options = {}) {
  const timeoutMs = positiveInteger(options.timeoutMs, DEFAULT_TIMEOUT_MS)
  // 0 means "follow no redirects" (requestLocalRuntimeHttp), not "use the default".
  const maxRedirects = options.maxRedirects === 0 ? 0 : positiveInteger(options.maxRedirects, DEFAULT_MAX_REDIRECTS)
  const maxResponseBytes = positiveInteger(options.maxResponseBytes, DEFAULT_MAX_RESPONSE_BYTES)
  const body = bodyBufferFor(options.body)
  const headers = { ...(options.headers || {}) }

  if (body && !Object.keys(headers).some((key) => key.toLowerCase() === 'content-length')) {
    headers['Content-Length'] = String(body.byteLength)
  }

  return requestHttpOnce(new URL(rawUrl), {
    method: options.method || 'GET',
    headers,
    body,
    timeoutMs,
    maxRedirects,
    maxResponseBytes,
  })
}

function requestHttpOnce(url, options) {
  return new Promise((resolve, reject) => {
    const request = transportFor(url).request(
      url,
      {
        method: options.method,
        headers: options.headers,
        timeout: options.timeoutMs,
      },
      (response) => {
        const status = response.statusCode || 0
        const redirectUrl = [301, 302, 303, 307, 308].includes(status)
          ? resolveRedirectURL(response.headers.location, url)
          : null

        if (redirectUrl) {
          response.resume()
          if (options.maxRedirects <= 0) {
            reject(new RoachNetHTTPError(`Too many redirects while requesting ${url}`, { statusCode: 310 }))
            return
          }

          const nextMethod = status === 303 ? 'GET' : options.method
          const nextBody = nextMethod === 'GET' || nextMethod === 'HEAD' ? null : options.body
          const nextHeaders = { ...options.headers }
          if (!nextBody) {
            delete nextHeaders['Content-Length']
            delete nextHeaders['content-length']
          }

          requestHttpOnce(redirectUrl, {
            ...options,
            method: nextMethod,
            headers: nextHeaders,
            body: nextBody,
            maxRedirects: options.maxRedirects - 1,
          }).then(resolve, reject)
          return
        }

        const chunks = []
        let size = 0
        response.on('data', (chunk) => {
          const buffer = Buffer.from(chunk)
          size += buffer.byteLength
          if (size > options.maxResponseBytes) {
            response.destroy(
              new RoachNetHTTPError(`Response from ${url} exceeded ${options.maxResponseBytes} bytes.`, {
                statusCode: 502,
              })
            )
            return
          }
          chunks.push(buffer)
        })
        response.on('end', () => {
          const buffer = Buffer.concat(chunks)
          resolve({
            ok: status >= 200 && status < 300,
            status,
            statusText: response.statusMessage || '',
            headers: response.headers,
            body: buffer,
            text: async () => buffer.toString('utf8'),
            json: async () => JSON.parse(buffer.toString('utf8')),
            arrayBuffer: async () =>
              buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength),
          })
        })
        response.on('error', reject)
      }
    )

    request.once('timeout', () => {
      request.destroy(new RoachNetHTTPError(`Request to ${url} timed out after ${options.timeoutMs}ms.`, {
        code: 'ETIMEDOUT',
        statusCode: 504,
      }))
    })
    request.once('error', reject)

    if (options.body) {
      request.write(options.body)
    }
    request.end()
  })
}

export async function downloadHttpToFile(rawUrl, destinationPath, options = {}) {
  const timeoutMs = positiveInteger(options.timeoutMs, DEFAULT_TIMEOUT_MS)
  const maxRedirects = positiveInteger(options.maxRedirects, DEFAULT_MAX_REDIRECTS)
  const maxDownloadBytes = positiveInteger(options.maxDownloadBytes, DEFAULT_MAX_DOWNLOAD_BYTES)
  const partialPath = options.partialPath || `${destinationPath}.part`

  rmSync(partialPath, { force: true })

  try {
    await downloadHttpToFileOnce(new URL(rawUrl), partialPath, {
      headers: { ...(options.headers || {}) },
      timeoutMs,
      maxRedirects,
      maxDownloadBytes,
    })
    renameSync(partialPath, destinationPath)
    return destinationPath
  } catch (error) {
    rmSync(partialPath, { force: true })
    throw error
  }
}

function downloadHttpToFileOnce(url, destinationPath, options) {
  return new Promise((resolve, reject) => {
    const request = transportFor(url).request(
      url,
      {
        method: 'GET',
        headers: options.headers,
        timeout: options.timeoutMs,
      },
      async (response) => {
        const status = response.statusCode || 0
        const redirectUrl = [301, 302, 303, 307, 308].includes(status)
          ? resolveRedirectURL(response.headers.location, url)
          : null

        if (redirectUrl) {
          response.resume()
          if (options.maxRedirects <= 0) {
            reject(new RoachNetHTTPError(`Too many redirects while downloading ${url}`, { statusCode: 310 }))
            return
          }

          downloadHttpToFileOnce(redirectUrl, destinationPath, {
            ...options,
            maxRedirects: options.maxRedirects - 1,
          }).then(resolve, reject)
          return
        }

        if (status < 200 || status >= 300) {
          response.resume()
          reject(new RoachNetHTTPError(`Download failed for ${url}: ${status} ${response.statusMessage || ''}`, {
            statusCode: status,
          }))
          return
        }

        const contentLength = Number(response.headers['content-length'] || 0)
        if (contentLength > options.maxDownloadBytes) {
          response.resume()
          reject(new RoachNetHTTPError(`Download from ${url} exceeded ${options.maxDownloadBytes} bytes.`, {
            statusCode: 502,
          }))
          return
        }

        let received = 0
        const byteLimit = new Transform({
          transform(chunk, _encoding, callback) {
            received += Buffer.byteLength(chunk)
            if (received > options.maxDownloadBytes) {
              callback(new RoachNetHTTPError(`Download from ${url} exceeded ${options.maxDownloadBytes} bytes.`, {
                statusCode: 502,
              }))
              return
            }

            callback(null, chunk)
          },
        })

        try {
          await pipeline(response, byteLimit, createWriteStream(destinationPath))
          resolve(destinationPath)
        } catch (error) {
          reject(error)
        }
      }
    )

    request.once('timeout', () => {
      request.destroy(new RoachNetHTTPError(`Download from ${url} timed out after ${options.timeoutMs}ms.`, {
        code: 'ETIMEDOUT',
        statusCode: 504,
      }))
    })
    request.once('error', reject)
    request.end()
  })
}
