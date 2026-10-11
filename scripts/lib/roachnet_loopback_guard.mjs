// Request checks for the loopback services written in JavaScript (the setup
// service and the legacy native API). They take the same stance as the Swift
// runtime (NativeRuntime.isTrustedLoopbackHost / isTrustedLoopbackOrigin /
// declaresJSONBody): answer only requests that a page on another site cannot
// make or read.
//
// - Host must name a loopback address. A page whose own DNS name was rebound
//   to 127.0.0.1 sends its own name, so it cannot read responses.
// - Origin, when a browser sends one, must be a loopback origin. Browsers send
//   Origin on every cross-origin POST, including "simple" ones that skip the
//   CORS preflight, so a page elsewhere cannot fire requests either.
// - A request body must be declared as JSON. A page on another origin cannot
//   send that without a preflight, and these services answer none.

const IPV4_LOOPBACK = /^127\.(?:\d{1,3})\.(?:\d{1,3})\.(?:\d{1,3})$/

export function isLoopbackHostname(rawHostname) {
  let hostname = String(rawHostname ?? '').trim().toLowerCase()
  if (hostname.startsWith('[') && hostname.endsWith(']')) hostname = hostname.slice(1, -1)
  if (hostname === 'localhost' || hostname === '::1' || hostname === '::ffff:127.0.0.1') return true
  if (!IPV4_LOOPBACK.test(hostname)) return false
  return hostname.split('.').every((part) => Number(part) <= 255)
}

// `Host` header value: `127.0.0.1:8080`, `localhost`, `[::1]:8080`. A request
// with no Host at all (HTTP/1.0, in-process callers) is not from a browser.
export function isTrustedLoopbackHost(rawHost) {
  if (rawHost === undefined || rawHost === null) return true
  const value = String(rawHost).trim()
  if (!value) return true
  let hostname = value
  if (value.startsWith('[')) {
    const close = value.indexOf(']')
    if (close === -1) return false
    hostname = value.slice(0, close + 1)
    const rest = value.slice(close + 1)
    if (rest && !/^:\d{1,5}$/.test(rest)) return false
  } else {
    const parts = value.split(':')
    if (parts.length > 2) return false
    if (parts.length === 2 && !/^\d{1,5}$/.test(parts[1])) return false
    hostname = parts[0]
  }
  return isLoopbackHostname(hostname)
}

// `Origin` header value. Absent means the caller is not a browser page (or is a
// same-origin GET); `null` comes from sandboxed frames and files and is refused.
export function isTrustedLoopbackOrigin(rawOrigin) {
  if (rawOrigin === undefined || rawOrigin === null) return true
  try {
    const origin = new URL(String(rawOrigin).trim())
    return ['http:', 'https:'].includes(origin.protocol) && isLoopbackHostname(origin.hostname)
  } catch {
    return false
  }
}

export function declaresJsonBody(headers = {}) {
  const type = String(headers['content-type'] || '').split(';')[0].trim().toLowerCase()
  return type === 'application/json' || type.endsWith('+json')
}

// Returns null when the request may go on, or { statusCode, error } to send.
export function loopbackRequestRejection(request, label = 'Loopback API') {
  const headers = request?.headers || {}
  if (!isTrustedLoopbackHost(headers.host)) {
    return { statusCode: 403, error: `${label} requests must use a loopback Host.` }
  }
  if (!isTrustedLoopbackOrigin(headers.origin)) {
    return { statusCode: 403, error: `${label} requests from other sites are refused.` }
  }
  return null
}

export class UnsupportedMediaTypeError extends Error {
  constructor() {
    super('Request body must be sent as application/json.')
    this.statusCode = 415
  }
}

// The loopback API's own credential, the same rules as the Swift runtime
// (LoopbackAPIToken.swift, ROA-39). Only enforced when whoever starts the
// runtime sets ROACHNET_API_TOKEN (RoachNet.app does, per launch).
const CHAT_PREFIXES = ['/api/ollama/chat', '/api/companion/chat', '/api/roachclaw/chat', '/api/roachclaw/sessions', '/api/chat']

export function apiTokenScope(method, pathname) {
  if (CHAT_PREFIXES.some((prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`))) return 'chat'
  if (method === 'GET' || method === 'HEAD') return 'read'
  return 'admin'
}

export function presentedApiToken(headers = {}) {
  const header = String(headers['x-roachnet-api-token'] || '').trim()
  if (header) return header
  const authorization = String(headers.authorization || '').trim()
  const match = /^bearer\s+(.+)$/i.exec(authorization)
  return match ? match[1].trim() : ''
}

function constantTimeEquals(left, right) {
  const a = Buffer.from(String(left))
  const b = Buffer.from(String(right))
  if (a.length !== b.length) return false
  let difference = 0
  for (let index = 0; index < a.length; index += 1) difference |= a[index] ^ b[index]
  return difference === 0
}

// `lookupToken(rawToken)` returns the stored record ({ isActive, scopes }) or null.
// Returns null when the request may go on, or { statusCode, error } to send.
export function apiTokenRejection(request, { requiredToken, lookupToken = () => null } = {}) {
  if (!requiredToken) return null
  const headers = request?.headers || {}
  const url = new URL(request?.url || '/', 'http://127.0.0.1')
  const method = request?.method || 'GET'
  if (method === 'GET' && url.pathname === '/api/health') return null
  if ((url.pathname === '/api/org' || url.pathname.startsWith('/api/org/')) && String(headers['x-roachnet-org-key'] || '').trim()) return null
  const presented = presentedApiToken(headers)
  if (!presented) {
    return { statusCode: 401, error: 'This RoachNet API needs its token. RoachNet passes it automatically; scripts can use a RoachClaw API token from Settings.' }
  }
  if (constantTimeEquals(presented, requiredToken)) return null
  if (presented.startsWith('rn_')) {
    const record = lookupToken(presented)
    if (record && record.isActive) {
      const scope = apiTokenScope(method, url.pathname)
      const scopes = Array.isArray(record.scopes) ? record.scopes : []
      if (scopes.includes(scope) || scopes.includes('admin')) return null
      return { statusCode: 403, error: `That API token can't use this route (it needs "${scope}"; the token has ${scopes.join(', ')}).`, requiredScope: scope }
    }
  }
  return { statusCode: 401, error: 'That RoachNet API token is not valid.' }
}
