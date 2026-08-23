#!/usr/bin/env node

import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

import { requestHttp } from './lib/roachnet_http.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const metadataPath = path.join(repoRoot, 'docs', 'release-gates', 'runtime-freshness.json')
const hermesEvaluationPath = path.join(repoRoot, 'docs', 'ROACHCLAW_HERMES_AGENT_EVALUATION.md')
const roachClawAgentPath = path.join(repoRoot, 'scripts', 'lib', 'roachnet_roachclaw_agent.mjs')
const buildScriptPath = path.join(repoRoot, 'scripts', 'build-native-macos-apps.mjs')
const setupBundleAssetsPath = path.join(
  repoRoot,
  'native',
  'macos',
  'dist',
  'RoachNet Setup.app',
  'Contents',
  'Resources',
  'InstallerAssets'
)

function displayPath(filePath) {
  return path.relative(repoRoot, filePath) || filePath
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message)
  }
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, 'utf8'))
}

function stripVersionPrefix(version) {
  return String(version || '').trim().replace(/^v/i, '')
}

async function fetchJson(url, headers = {}) {
  const token = process.env.GITHUB_TOKEN?.trim() || process.env.GH_TOKEN?.trim() || ''
  const authHeaders = token && String(url).startsWith('https://api.github.com/')
    ? { authorization: `Bearer ${token}` }
    : {}
  const response = await requestHttp(url, {
    headers: {
      accept: 'application/json',
      'user-agent': 'RoachNet-Runtime-Freshness-Audit',
      ...authHeaders,
      ...headers,
    },
    timeoutMs: 30_000,
  })

  if (!response.ok) {
    throw new Error(`Request to ${url} failed with ${response.status} ${response.statusText}`)
  }

  return response.json()
}

async function fetchLatestNodeForChannel(channel) {
  const releases = await fetchJson('https://nodejs.org/dist/index.json')
  const release = releases.find((entry) => String(entry.version || '').startsWith(`v${channel}.`))
  return release?.version || null
}

async function fetchLatestOllama() {
  const release = await fetchJson('https://api.github.com/repos/ollama/ollama/releases/latest')
  return release?.tag_name || null
}

async function fetchLatestNpmPackage(packageName) {
  const response = await requestHttp(`https://registry.npmjs.org/${encodeURIComponent(packageName)}/latest`, {
    headers: {
      accept: 'application/json',
      'user-agent': 'RoachNet-Runtime-Freshness-Audit',
    },
    timeoutMs: 30_000,
  })

  if (!response.ok) {
    throw new Error(`Request to npm registry for ${packageName} failed with ${response.status} ${response.statusText}`)
  }

  const payload = await response.json()
  return payload?.version || null
}

function assertBuildScriptMatchesMetadata(metadata) {
  const source = readFileSync(buildScriptPath, 'utf8')
  assert(
    source.includes('const bundledNodeVersion = runtimePins.node?.bundledVersion') &&
      source.includes('requireFileSha256') &&
      source.includes('ROACHNET_RELEASE_BUILD'),
    `Native builder does not source checksum-pinned runtime metadata in fail-closed release mode.`
  )
  assert(
    /^[a-f0-9]{64}$/i.test(metadata.node.artifacts.darwinArm64.sha256) &&
      /^[a-f0-9]{64}$/i.test(metadata.node.artifacts.darwinX64.sha256) &&
      /^[a-f0-9]{64}$/i.test(metadata.ollama.artifact.sha256),
    'Node and Ollama release artifacts must have reviewed SHA-256 pins.'
  )
  assert(
    metadata.openclaw.mode === 'deferred-not-bundled' && metadata.openclaw.bundledPackage === null,
    'OpenClaw must remain explicitly absent from the public candidate artifact.'
  )
}

function assertRoachClawAgentRewriteMatchesMetadata(metadata) {
  const agent = metadata.roachClawAgent
  assert(agent?.mode === 'native-rewrite', 'RoachClaw agent metadata must declare mode native-rewrite.')
  assert(agent?.upstreamRuntimeDependency === 'none', 'RoachClaw agent metadata must not declare an upstream runtime dependency.')
  assert(agent?.runtimeModule === 'scripts/lib/roachnet_roachclaw_agent.mjs', 'RoachClaw agent metadata points at the wrong runtime module.')
  assert(agent?.hermesReference?.role === 'design-reference-only', 'Hermes must be recorded as design-reference-only.')
  assert(agent?.hermesReference?.reviewedHead, 'Hermes reference must keep the reviewed commit for auditability.')
  assert(existsSync(roachClawAgentPath), `Missing RoachClaw native agent module at ${roachClawAgentPath}.`)
  assert(existsSync(hermesEvaluationPath), `Missing Hermes Agent evaluation at ${hermesEvaluationPath}.`)

  const agentSource = readFileSync(roachClawAgentPath, 'utf8')
  const source = readFileSync(hermesEvaluationPath, 'utf8')
  assert(
    source.includes(agent.hermesReference.reviewedHead),
    `Hermes Agent evaluation does not cite reviewed HEAD ${agent.hermesReference.reviewedHead}.`
  )
  assert(
    agentSource.includes(`ROACHCLAW_AGENT_REVIEWED_HERMES_HEAD = '${agent.hermesReference.reviewedHead}'`),
    `RoachClaw native agent module reviewed Hermes HEAD does not match ${metadataPath}.`
  )
  assert(
    source.includes('not a runtime dependency') && source.includes('not vendored code'),
    'Hermes Agent evaluation must make clear Hermes is a reference, not a runtime dependency.'
  )
  assert(
    agentSource.includes('roachclaw-native-agent') &&
      agentSource.includes("upstreamRuntimeDependency: 'none'") &&
      agentSource.includes('design-reference-only') &&
      agentSource.includes('4_096'),
    'RoachClaw native agent module is missing runtime, dependency, reference, or budget guards.'
  )
  assert(
    !/from ['"].*hermes|import\(.*hermes|github\.com\/NousResearch\/hermes-agent/i.test(agentSource),
    'RoachClaw native agent module must not import or fetch Hermes.'
  )

  for (const forbiddenPath of [
    'hermes-agent',
    'vendor/hermes-agent',
    'third_party/hermes-agent',
    'external/hermes-agent',
    'native/macos/Sources/HermesAgent',
  ]) {
    assert(!existsSync(path.join(repoRoot, forbiddenPath)), `Hermes source must not be vendored into ${forbiddenPath}.`)
  }

  assert(
    source.includes('OpenClaw fallback') && source.includes('fresh install'),
    'RoachClaw native replacement work must remain additive until fresh-install and upgrade parity are proven.'
  )
}

function assertBundledNodeBinaryVersion(nodePath, expectedVersion) {
  const result = spawnSync(nodePath, ['--version'], {
    encoding: 'utf8',
    timeout: 180_000,
  })
  assert(
    result.status === 0,
    `Bundled Node runtime at ${nodePath} did not execute cleanly: ${
      result.error?.message || result.stderr || result.stdout || result.signal || `exit ${result.status}`
    }`
  )
  const actualVersion = String(result.stdout || '').trim()
  assert(
    actualVersion === expectedVersion,
    [
      `Bundled Node runtime at ${displayPath(nodePath)} is ${actualVersion || 'unknown'}, expected ${expectedVersion}.`,
      `This usually means native/macos/dist is stale after a runtime metadata update.`,
      `Rebuild the final app and DMG with scripts/build-native-macos-apps.mjs, then rerun this gate.`,
    ].join(' ')
  )
}

function assertDistributionMatchesMetadata(metadata) {
  const setupNode = path.join(
    repoRoot,
    'native',
    'macos',
    'dist',
    'RoachNet Setup.app',
    'Contents',
    'Resources',
    'EmbeddedRuntime',
    'node',
    'bin',
    'node'
  )
  const appNode = path.join(
    repoRoot,
    'native',
    'macos',
    'dist',
    'RoachNet.app',
    'Contents',
    'Resources',
    'EmbeddedRuntime',
    'node',
    'bin',
    'node'
  )

  if (existsSync(setupNode) || existsSync(appNode)) {
    for (const nodePath of [setupNode, appNode]) {
      assert(existsSync(nodePath), `Expected bundled Node runtime at ${nodePath}.`)
      assertBundledNodeBinaryVersion(nodePath, metadata.node.bundledVersion)
    }
  }

  if (existsSync(setupBundleAssetsPath)) {
    const ollamaArchive = path.join(setupBundleAssetsPath, 'bundled-ollama.tar.gz')
    const openclawArchive = path.join(setupBundleAssetsPath, 'bundled-openclaw.tar.gz')
    const openclawDeferred = path.join(setupBundleAssetsPath, 'openclaw-deferred.marker')
    assert(existsSync(ollamaArchive), 'Setup bundle is missing bundled-ollama.tar.gz.')

    if (metadata.openclaw.mode === 'deferred-not-bundled') {
      assert(existsSync(openclawDeferred), 'Setup bundle must include openclaw-deferred.marker when OpenClaw is deferred.')
      assert(!existsSync(openclawArchive), 'Setup bundle should not include bundled-openclaw.tar.gz while OpenClaw is deferred.')
    } else {
      assert(existsSync(openclawArchive), 'Setup bundle must include bundled-openclaw.tar.gz when OpenClaw is bundled.')
    }
  }
}

async function main() {
  assert(existsSync(metadataPath), `Missing runtime freshness metadata at ${metadataPath}.`)
  const metadata = readJson(metadataPath)

  assertBuildScriptMatchesMetadata(metadata)
  assertRoachClawAgentRewriteMatchesMetadata(metadata)
  assertDistributionMatchesMetadata(metadata)

  const [latestNode, latestOllama, latestOpenClaw] = await Promise.all([
    fetchLatestNodeForChannel(metadata.node.channel),
    fetchLatestOllama(),
    fetchLatestNpmPackage('openclaw'),
  ])

  assert(latestNode, 'Could not resolve latest Node release.')
  assert(latestOllama, 'Could not resolve latest Ollama release.')
  assert(latestOpenClaw, 'Could not resolve latest OpenClaw package release.')

  assert(
    stripVersionPrefix(metadata.node.bundledVersion) === stripVersionPrefix(latestNode),
    `Bundled Node is stale: metadata has ${metadata.node.bundledVersion}, latest ${latestNode}.`
  )
  assert(
    stripVersionPrefix(metadata.ollama.bundledVersion) === stripVersionPrefix(latestOllama),
    `Bundled Ollama is stale: metadata has ${metadata.ollama.bundledVersion}, latest ${latestOllama}.`
  )
  assert(
    stripVersionPrefix(metadata.openclaw.reviewedVersion) === stripVersionPrefix(latestOpenClaw),
    `OpenClaw metadata is stale: metadata has ${metadata.openclaw.reviewedVersion}, latest ${latestOpenClaw}.`
  )

  console.log(
    [
      `Runtime freshness audit passed.`,
      `Node ${metadata.node.bundledVersion}.`,
      `Ollama ${metadata.ollama.bundledVersion}.`,
      `OpenClaw ${metadata.openclaw.reviewedVersion} (${metadata.openclaw.mode}).`,
      `RoachClaw native agent rewrite.`,
      `Hermes reference ${metadata.roachClawAgent.hermesReference.reviewedHead.slice(0, 12)}.`,
    ].join(' ')
  )
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
