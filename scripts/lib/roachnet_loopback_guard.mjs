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
