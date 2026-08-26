import net from 'node:net'

const LOOPBACK_TARGET_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '::ffff:127.0.0.1'])

function normalizedHost(rawValue) {
  return String(rawValue || '')
    .trim()
    .replace(/^\[|\]$/g, '')
    .replace(/\.$/, '')
    .toLowerCase()
}

function hostnameForChecks(rawValue) {
  const trimmed = String(rawValue || '').trim()
  if (!trimmed) {
    return ''
  }

  try {
    const parsed = new URL(trimmed)
    if (parsed.hostname) {
      return normalizedHost(parsed.hostname)
    }
  } catch {
    // Continue with host/header style parsing below.
  }

  if (trimmed.startsWith('[')) {
    const closingBracket = trimmed.indexOf(']')
    return closingBracket > 0 ? normalizedHost(trimmed.slice(1, closingBracket)) : normalizedHost(trimmed)
  }

  const colonCount = [...trimmed].filter((character) => character === ':').length
  if (colonCount === 1) {
    return normalizedHost(trimmed.split(':')[0])
  }

  return normalizedHost(trimmed)
}

function hostForDisplay(rawValue) {
  const trimmed = String(rawValue || '').trim()
  if (!trimmed) {
    return ''
  }

  try {
    const parsed = new URL(trimmed)
    if (parsed.host || parsed.hostname) {
      return parsed.host || parsed.hostname
    }
  } catch {
    // Continue with the raw host/header value below.
  }

  return trimmed
}

export function isIPAddressHost(rawValue) {
  return net.isIP(hostnameForChecks(rawValue)) !== 0
}

export function isLocalRuntimeTargetHost(rawValue) {
  const host = hostnameForChecks(rawValue)
  return LOOPBACK_TARGET_HOSTS.has(host)
}

export function assertCompanionBindHost(rawValue) {
  const host = String(rawValue || '').trim()
  if (!host || !isLocalRuntimeTargetHost(host)) {
    throw new Error('RoachNet companion server must bind only to a loopback address.')
  }
  return host
}

export function resolveCompanionTargetOrigin(rawValue) {
  const parsed = new URL(String(rawValue || '').trim())
  if (!['http:', 'https:'].includes(parsed.protocol)) {
    throw new Error('RoachNet companion target must use http or https.')
  }
  if (parsed.username || parsed.password) {
    throw new Error('RoachNet companion target must not include credentials.')
  }
  if (!isLocalRuntimeTargetHost(parsed.hostname)) {
    throw new Error('RoachNet companion target must point at the local desktop runtime.')
  }
  return parsed.origin
}

export function isCompanionProxyPath(pathname) {
  return pathname === '/api/companion' || pathname.startsWith('/api/companion/')
}

export function buildUpstreamCompanionUrl(requestUrl, targetOrigin) {
  const pathname = requestUrl.pathname
  if (!isCompanionProxyPath(pathname) || pathname.startsWith('//')) {
    throw new Error('Unsupported companion proxy path.')
  }

  const upstreamUrl = new URL(resolveCompanionTargetOrigin(targetOrigin))
  upstreamUrl.pathname = pathname
  upstreamUrl.search = requestUrl.search
  return upstreamUrl
}

export function sanitizeUserFacingHost(rawValue, fallbackHost = 'RoachNet') {
  const displayHost = hostForDisplay(rawValue)
  if (!displayHost) {
    return fallbackHost
  }

  const checkHost = hostnameForChecks(displayHost)
  if (!checkHost || isLocalRuntimeTargetHost(checkHost) || net.isIP(checkHost) !== 0) {
    return fallbackHost
  }

  return displayHost
}
