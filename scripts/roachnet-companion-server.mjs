#!/usr/bin/env node

import { createServer } from 'node:http'
import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'

const host = process.env.ROACHNET_COMPANION_HOST?.trim() || '0.0.0.0'
const port = Number(process.env.ROACHNET_COMPANION_PORT || '38111')
const token = process.env.ROACHNET_COMPANION_TOKEN?.trim() || ''
const targetOrigin = process.env.ROACHNET_COMPANION_TARGET_URL?.trim() || 'http://127.0.0.1:8080'
const storagePath =
  process.env.ROACHNET_STORAGE_PATH?.trim() || process.env.ROACHNET_HOST_STORAGE_PATH?.trim() || ''
const roachTailStatePath = storagePath ? path.join(storagePath, 'vault', 'roachtail', 'state.json') : ''
const roachNetAliasHost = process.env.ROACHNET_LOCAL_HOSTNAME?.trim() || 'RoachNet'

function writeJson(response, statusCode, payload) {
  const body = JSON.stringify(payload)
  response.writeHead(statusCode, {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-RoachNet-Companion-Token',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
  })
  response.end(body)
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = []

    request.on('data', (chunk) => chunks.push(Buffer.from(chunk)))
    request.on('end', () => resolve(Buffer.concat(chunks)))
    request.on('error', reject)
  })
}

function extractToken(request) {
  const authorization = request.headers.authorization?.trim()
  if (authorization?.toLowerCase().startsWith('bearer ')) {
    return authorization.slice(7).trim()
  }

  const headerToken = request.headers['x-roachnet-companion-token']
  if (Array.isArray(headerToken)) {
    return headerToken[0]?.trim() || ''
  }

  return headerToken?.trim() || ''
}

function hashToken(value) {
  return createHash('sha256').update(value).digest('hex')
}

function isIPAddress(host) {
  const normalized = host.trim().replace(/^\[|\]$/g, '')
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(normalized) || /^[0-9a-f:]+$/i.test(normalized)
}

function isLoopbackHost(host) {
  const normalized = host.trim().replace(/^\[|\]$/g, '').toLowerCase()
  return normalized === 'localhost' || normalized === '127.0.0.1' || normalized === '::1' || normalized === '0.0.0.0'
}

function sanitizeUserFacingHost(rawValue) {
  const trimmed = rawValue?.trim()
  if (!trimmed) {
    return roachNetAliasHost
  }

  try {
    const parsed = new URL(trimmed)
    if (isLoopbackHost(parsed.hostname) || isIPAddress(parsed.hostname)) {
      return roachNetAliasHost
    }
    return parsed.host || parsed.hostname || roachNetAliasHost
  } catch {
    if (isLoopbackHost(trimmed) || isIPAddress(trimmed)) {
      return roachNetAliasHost
    }
    return trimmed
  }
}

async function resolvePeerToken(tokenValue, { allowDisabled = false } = {}) {
  if (!roachTailStatePath || !tokenValue) {
    return null
  }

  try {
    const raw = await readFile(roachTailStatePath, 'utf8')
    const parsed = JSON.parse(raw)
    if ((!parsed?.enabled && !allowDisabled) || !Array.isArray(parsed.peers)) {
      return null
    }

    const hashed = hashToken(tokenValue)
    return (
      parsed.peers.find(
        (peer) =>
          peer &&
          typeof peer === 'object' &&
          typeof peer.id === 'string' &&
          typeof peer.tokenHash === 'string' &&
          peer.tokenHash === hashed
      ) || null
    )
  } catch {
    return null
  }
}

function peerCanUseWhenDisabled(pathname, request) {
  if (!pathname.startsWith('/api/companion/roachtail')) {
    return false
  }

  if (request.method === 'GET') {
    return pathname === '/api/companion/roachtail'
  }

  return pathname === '/api/companion/roachtail/affect'
}

async function resolveAuthorization(request, pathname) {
  const providedToken = extractToken(request)
  if (!providedToken) {
    return null
  }

  if (token && providedToken === token) {
    return { kind: 'primary' }
  }

  const peer = await resolvePeerToken(providedToken, {
    allowDisabled: peerCanUseWhenDisabled(pathname, request),
  })
  if (peer) {
    return {
      kind: 'peer',
      peerId: peer.id,
      peerName: typeof peer.name === 'string' ? peer.name : 'Linked device',
    }
  }

  return null
}

function requestPeerEndpoint(request) {
  const forwardedHost = request.headers['x-forwarded-host']
  const forwardedHostValue = Array.isArray(forwardedHost) ? forwardedHost[0] : forwardedHost
  if (forwardedHostValue?.trim()) {
    return sanitizeUserFacingHost(forwardedHostValue)
  }

  const forwardedFor = request.headers['x-forwarded-for']
  const forwardedValue = Array.isArray(forwardedFor) ? forwardedFor[0] : forwardedFor
  const firstForwarded = forwardedValue?.split(',')[0]?.trim()
  if (firstForwarded) {
    return sanitizeUserFacingHost(firstForwarded)
  }

  const remoteAddress = request.socket.remoteAddress?.trim()
  if (remoteAddress) {
    return sanitizeUserFacingHost(remoteAddress)
  }

  return roachNetAliasHost
}

async function recordPeerActivity(authContext, request) {
  if (!roachTailStatePath || authContext?.kind !== 'peer') {
    return
  }

  try {
    const raw = await readFile(roachTailStatePath, 'utf8')
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.peers)) {
      return
    }

    const peerIndex = parsed.peers.findIndex(
      (peer) =>
        peer &&
        typeof peer === 'object' &&
        typeof peer.id === 'string' &&
        peer.id === authContext.peerId
    )
    if (peerIndex === -1) {
      return
    }

    const nextState = {
      ...parsed,
      status: parsed.enabled ? 'connected' : parsed.status || 'local-only',
      lastUpdatedAt: new Date().toISOString(),
      peers: parsed.peers.map((peer, index) =>
        index === peerIndex
          ? {
              ...peer,
              status: parsed.enabled ? 'connected' : 'paired',
              lastSeenAt: new Date().toISOString(),
              endpoint: requestPeerEndpoint(request) || peer.endpoint || null,
            }
          : peer
      ),
    }

    await writeFile(roachTailStatePath, JSON.stringify(nextState, null, 2), 'utf8')
  } catch {
    // Keep proxying even if peer activity could not be persisted.
  }
}

async function proxyRequest(request, response, pathname, authContext = null) {
  const upstreamUrl = new URL(pathname, targetOrigin)
  const method = request.method || 'GET'
  const bodyBuffer = method === 'GET' || method === 'HEAD' ? null : await readBody(request)

  const upstreamHeaders = {
    Accept: 'application/json',
    'Content-Type': request.headers['content-type'] || 'application/json',
  }

  if (authContext?.kind === 'peer') {
    upstreamHeaders['X-RoachTail-Peer-ID'] = authContext.peerId
    upstreamHeaders['X-RoachTail-Peer-Name'] = authContext.peerName
  }
  if (authContext?.kind) {
    upstreamHeaders['X-RoachTail-Auth-Kind'] = authContext.kind
  }
  if (authContext?.peerId) {
    upstreamHeaders['X-RoachTail-Auth-Peer-ID'] = authContext.peerId
  }

  await recordPeerActivity(authContext, request)

  const upstreamResponse = await fetch(upstreamUrl, {
    method,
    headers: upstreamHeaders,
    body: bodyBuffer && bodyBuffer.length > 0 ? bodyBuffer : undefined,
  })

  const payload = Buffer.from(await upstreamResponse.arrayBuffer())

  response.writeHead(upstreamResponse.status, {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-RoachNet-Companion-Token',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Cache-Control': 'no-store',
    'Content-Type': upstreamResponse.headers.get('content-type') || 'application/json; charset=utf-8',
  })
  response.end(payload)
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url || '/', 'http://roachnet-companion.local')
  const pathname = url.pathname

  if (request.method === 'OPTIONS') {
    response.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type, X-RoachNet-Companion-Token',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      'Cache-Control': 'no-store',
    })
    response.end()
    return
  }

  if (pathname === '/health') {
    writeJson(response, 200, {
      status: 'ok',
      targetOrigin,
      tokenConfigured: Boolean(token),
    })
    return
  }

  const pairingRequest = pathname === '/api/companion/roachtail/pair' && request.method === 'POST'

  if (!pathname.startsWith('/api/companion')) {
    writeJson(response, 404, {
      error: 'Not found',
    })
    return
  }

  const authContext = pairingRequest ? { kind: 'pairing' } : await resolveAuthorization(request, pathname)

  if (!authContext) {
    writeJson(response, 401, {
      error: 'Invalid or missing companion token',
    })
    return
  }

  try {
    await proxyRequest(request, response, `${pathname}${url.search}`, authContext)
  } catch (error) {
    writeJson(response, 502, {
      error: error instanceof Error ? error.message : 'Failed to proxy companion request',
    })
  }
})

server.listen(port, host, () => {
  console.log(`RoachNet companion server listening on http://${host}:${port}`)
})

function shutdown() {
  server.close(() => {
    process.exit(0)
  })
}

process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
