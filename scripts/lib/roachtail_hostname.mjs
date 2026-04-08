import { lookup } from 'node:dns/promises'

export const DEFAULT_ROACHTAIL_LOCAL_HOSTNAME = 'RoachNet'
export const ROACHTAIL_HOSTS_BLOCK_BEGIN = '# >>> RoachNet local alias >>>'
export const ROACHTAIL_HOSTS_BLOCK_END = '# <<< RoachNet local alias <<<'

function escapeShellSingleQuotes(value) {
  return String(value).replace(/'/g, `'\"'\"'`)
}

function normalizeHostName(host) {
  return String(host || '')
    .trim()
    .replace(/^\[|\]$/g, '')
    .toLowerCase()
}

function isLoopbackAddress(address) {
  const normalized = normalizeHostName(address)
  return normalized === '127.0.0.1' || normalized === '::1'
}

export function getRoachNetLocalHostname(envValues = process.env) {
  return envValues.ROACHNET_LOCAL_HOSTNAME?.trim() || DEFAULT_ROACHTAIL_LOCAL_HOSTNAME
}

export function buildRoachNetLocalAliasBlock(hostname) {
  const resolvedHost = getRoachNetLocalHostname({ ROACHNET_LOCAL_HOSTNAME: hostname })
  return [
    ROACHTAIL_HOSTS_BLOCK_BEGIN,
    `127.0.0.1 ${resolvedHost}`,
    `::1 ${resolvedHost}`,
    ROACHTAIL_HOSTS_BLOCK_END,
  ].join('\n')
}

export function stripRoachNetLocalAliasBlock(content) {
  const lines = String(content || '').split(/\r?\n/)
  const nextLines = []
  let skipping = false

  for (const line of lines) {
    if (line.trim() === ROACHTAIL_HOSTS_BLOCK_BEGIN) {
      skipping = true
      continue
    }

    if (line.trim() === ROACHTAIL_HOSTS_BLOCK_END) {
      skipping = false
      continue
    }

    if (!skipping) {
      nextLines.push(line)
    }
  }

  return nextLines.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd()
}

export function applyRoachNetLocalAliasToHosts(content, hostname) {
  const stripped = stripRoachNetLocalAliasBlock(content)
  const block = buildRoachNetLocalAliasBlock(hostname)
  return stripped ? `${stripped}\n\n${block}\n` : `${block}\n`
}

export function hostsFileHasRoachNetLocalAlias(content, hostname) {
  const normalizedHost = normalizeHostName(hostname)
  const lines = String(content || '').split(/\r?\n/)

  return lines.some((rawLine) => {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) {
      return false
    }

    const tokens = line.split(/\s+/)
    if (tokens.length < 2) {
      return false
    }

    return isLoopbackAddress(tokens[0]) && tokens.slice(1).some((token) => normalizeHostName(token) === normalizedHost)
  })
}

export async function roachNetHostnameResolvesToLoopback(hostname) {
  try {
    const addresses = await lookup(hostname, { all: true })
    return addresses.some((entry) => isLoopbackAddress(entry.address))
  } catch {
    return false
  }
}

export function buildRoachNetLocalAliasShellCommand(hostname, hostsFile = '/etc/hosts') {
  const escapedHostsFile = escapeShellSingleQuotes(hostsFile)
  const escapedHostname = escapeShellSingleQuotes(hostname)
  const escapedBegin = escapeShellSingleQuotes(ROACHTAIL_HOSTS_BLOCK_BEGIN)
  const escapedEnd = escapeShellSingleQuotes(ROACHTAIL_HOSTS_BLOCK_END)

  return [
    `HOSTS_FILE='${escapedHostsFile}'`,
    `ROACHNET_HOSTNAME='${escapedHostname}'`,
    `ROACHNET_ALIAS_BEGIN='${escapedBegin}'`,
    `ROACHNET_ALIAS_END='${escapedEnd}'`,
    "TMP_ROACHNET_HOSTS=$(mktemp \"${TMPDIR:-/tmp}/roachnet-hosts.XXXXXX\")",
    "trap 'rm -f \"$TMP_ROACHNET_HOSTS\" \"$TMP_ROACHNET_HOSTS.next\"' EXIT",
    "awk -v begin=\"$ROACHNET_ALIAS_BEGIN\" -v end=\"$ROACHNET_ALIAS_END\" 'BEGIN { skip = 0 } $0 == begin { skip = 1; next } $0 == end { skip = 0; next } !skip { print }' \"$HOSTS_FILE\" > \"$TMP_ROACHNET_HOSTS\"",
    "{",
    "  cat \"$TMP_ROACHNET_HOSTS\"",
    "  printf '\\n%s\\n127.0.0.1 %s\\n::1 %s\\n%s\\n' \"$ROACHNET_ALIAS_BEGIN\" \"$ROACHNET_HOSTNAME\" \"$ROACHNET_HOSTNAME\" \"$ROACHNET_ALIAS_END\"",
    "} > \"$TMP_ROACHNET_HOSTS.next\"",
    "cat \"$TMP_ROACHNET_HOSTS.next\" > \"$HOSTS_FILE\"",
    "dscacheutil -flushcache >/dev/null 2>&1 || true",
    "killall -HUP mDNSResponder >/dev/null 2>&1 || true",
  ].join('; ')
}
