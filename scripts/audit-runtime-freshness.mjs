#!/usr/bin/env node

// Checks docs/release-gates/runtime-freshness.json against the builder and the
// built apps: RoachNet ships its own Swift runtime and nothing else. No Node,
// no Ollama runner, no OpenClaw package and no copy of RoachNet's source.

import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { requestHttp } from './lib/roachnet_http.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const metadataPath = path.join(repoRoot, 'docs', 'release-gates', 'runtime-freshness.json')
const hermesEvaluationPath = path.join(repoRoot, 'docs', 'ROACHCLAW_HERMES_AGENT_EVALUATION.md')
const buildScriptPath = path.join(repoRoot, 'scripts', 'build-native-macos-apps.mjs')
const distRoot = path.join(repoRoot, 'native', 'macos', 'dist')
const setupBundleAssetsPath = path.join(distRoot, 'RoachNet Setup.app', 'Contents', 'Resources', 'InstallerAssets')

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

async function fetchLatestOllama() {
  const release = await fetchJson('https://api.github.com/repos/ollama/ollama/releases/latest')
  return release?.tag_name || null
}

async function fetchLatestNpmPackage(packageName) {
  const payload = await fetchJson(`https://registry.npmjs.org/${encodeURIComponent(packageName)}/latest`)
  return payload?.version || null
}

function ollamaRetired(metadata) {
  return metadata.ollama?.mode === 'retired-not-bundled'
}

function assertBuildScriptMatchesMetadata(metadata) {
  const source = readFileSync(buildScriptPath, 'utf8')
  assert(
    source.includes('requireFileSha256') &&
      source.includes('ROACHNET_RELEASE_BUILD') &&
      source.includes('ROACHNET_CANDIDATE_BUILD') &&
      source.includes('pinnedRuntimeBuild'),
    'Native builder does not keep its checksum-pinned release and credential-independent candidate modes.'
  )
  for (const retired of [
    'nodejs.org/dist',
    'EmbeddedRuntime',
    'bundledNodeVersion',
    'ensureBundledNodeRuntime',
    'createBundledSourceArchive',
    'ROACHNET_BUNDLE_NODE_COMPAT',
    'ROACHNET_BUNDLE_OPENCLAW',
  ]) {
    assert(!source.includes(retired), `Native builder still references ${retired}; RoachNet ships no Node runtime, OpenClaw package or source tree.`)
  }
  if (ollamaRetired(metadata)) {
    assert(
      !source.includes('ensureBundledOllamaCache') && source.includes("'bundled-ollama.tar.gz'"),
      'Native builder must not fetch Ollama and must clear stale bundled-ollama payloads once Ollama is retired.'
    )
  } else {
    assert(/^[a-f0-9]{64}$/i.test(metadata.ollama.artifact?.sha256 || ''), 'Ollama release artifact must have a reviewed SHA-256 pin.')
  }
  assert(
    source.includes("'bundled-openclaw.tar.gz'") && source.includes("'openclaw-deferred.marker'"),
    'Native builder must clear the OpenClaw payloads older builds left in InstallerAssets.'
  )
  assert(
    metadata.openclaw?.mode === 'external-not-bundled' && metadata.openclaw.bundledPackage === null,
    'OpenClaw must stay out of the apps: RoachNet only probes an OpenClaw the person runs themselves.'
  )
}

function assertNodeIsNotShipped(metadata) {
  const node = metadata.node
  assert(
    node?.mode === 'not-shipped',
    'runtime-freshness.json must record Node as not-shipped: RoachNet and RoachNet Setup contain and launch no Node.'
  )
  assert(
    node.artifacts === undefined && node.bundledVersion === undefined,
    'runtime-freshness.json must not pin Node release artifacts; no build downloads or embeds Node.'
  )
  const buildSource = readFileSync(buildScriptPath, 'utf8')
  assert(
    buildSource.includes("assertNoNodeOrJavaScript(desktopBundlePath, 'RoachNet')") &&
      buildSource.includes("assertNoNodeOrJavaScript(setupBundlePath, 'RoachNet Setup')"),
    'Native builder must refuse any bundle that carries Node, JavaScript or RoachNet source.'
  )
}

const swiftAgentModule = 'native/macos/Sources/RoachNetRuntime/RoachClawAgent.swift'

function assertRoachClawAgentRewriteMatchesMetadata(metadata) {
  const agent = metadata.roachClawAgent
  assert(agent?.mode === 'native-rewrite', 'RoachClaw agent metadata must declare mode native-rewrite.')
  assert(agent?.upstreamRuntimeDependency === 'none', 'RoachClaw agent metadata must not declare an upstream runtime dependency.')
  assert(agent?.runtimeModule === swiftAgentModule, `RoachClaw agent metadata must point at ${swiftAgentModule}.`)
  assert(agent?.hermesReference?.role === 'design-reference-only', 'Hermes must be recorded as design-reference-only.')
  const reviewedHead = agent?.hermesReference?.reviewedHead
  assert(reviewedHead, 'Hermes reference must keep the reviewed commit for auditability.')

  const agentPath = path.join(repoRoot, swiftAgentModule)
  assert(existsSync(agentPath), `Missing RoachClaw native agent at ${swiftAgentModule}.`)
  assert(existsSync(hermesEvaluationPath), `Missing Hermes Agent evaluation at ${displayPath(hermesEvaluationPath)}.`)
  const agentSource = readFileSync(agentPath, 'utf8')
  const evaluation = readFileSync(hermesEvaluationPath, 'utf8')

  assert(evaluation.includes(reviewedHead), `Hermes Agent evaluation does not cite reviewed HEAD ${reviewedHead}.`)
  assert(
    evaluation.includes('not a runtime dependency') && evaluation.includes('not vendored code'),
    'Hermes Agent evaluation must make clear Hermes is a reference, not a runtime dependency.'
  )
  assert(
    agentSource.includes(`reviewedHermesHead = "${reviewedHead}"`),
    `RoachClaw native agent reviewed Hermes HEAD does not match ${displayPath(metadataPath)}.`
  )
  assert(
    agentSource.includes('"roachclaw-native-agent"') &&
      /"upstreamRuntimeDependency": "none"/.test(agentSource) &&
      agentSource.includes('"design-reference-only"') &&
      agentSource.includes('4096'),
    'RoachClaw native agent is missing runtime, dependency, reference, or budget guards.'
  )
  assert(
    !/import\s+\w*[Hh]ermes|github\.com\/NousResearch\/hermes-agent/.test(agentSource),
    'RoachClaw native agent must not import or fetch Hermes.'
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
    evaluation.includes('OpenClaw fallback') && evaluation.includes('fresh install'),
    'RoachClaw native replacement work must remain additive until fresh-install and upgrade parity are proven.'
  )
}

function assertNativeRuntimeMatchesMetadata(metadata) {
  const runtime = metadata.nativeRuntime
  assert(runtime?.mode === 'swift-native', 'Runtime metadata must declare nativeRuntime.mode swift-native.')
  assert(runtime?.thirdPartyDependencies === 'none', 'Native runtime metadata must declare no third-party dependencies.')
  assert(existsSync(path.join(repoRoot, runtime.sourceRoot)), `Missing native runtime sources at ${runtime.sourceRoot}.`)
  assert(
    readFileSync(buildScriptPath, 'utf8').includes('copyNativeRuntimeHelper'),
    'Native builder must package the Swift runtime helper.'
  )
}

function assertDistributionMatchesMetadata(metadata) {
  const bundles = ['RoachNet Setup.app', 'RoachNet.app'].map((bundle) => path.join(distRoot, bundle, 'Contents'))
  if (!bundles.some((contents) => existsSync(contents))) {
    return
  }
  const distIsNative = bundles.every((contents) =>
    existsSync(path.join(contents, 'Helpers', metadata.nativeRuntime.executable))
  )
  if (!distIsNative) {
    // Bundles from before the native Swift runtime, left in the git-ignored dist
    // folder. They are not what ships; say so instead of checking them.
    console.warn('notice: native/macos/dist predates the native Swift runtime; rebuild with npm run native:dist before the release gate.')
    if (process.env.ROACHNET_REQUIRE_FRESH_DIST === '1') {
      throw new Error('native/macos/dist is stale: bundles are missing Contents/Helpers/roachnet-runtime.')
    }
    return
  }

  for (const contents of bundles) {
    for (const retired of ['EmbeddedRuntime', 'RoachNetSource', 'RoachNetSource.tar.gz']) {
      const retiredPath = path.join(contents, 'Resources', retired)
      assert(
        !existsSync(retiredPath),
        `${displayPath(retiredPath)} must not be present: the apps must not carry a Node runtime or RoachNet's source.`
      )
    }
  }

  if (existsSync(setupBundleAssetsPath)) {
    const ollamaArchive = path.join(setupBundleAssetsPath, 'bundled-ollama.tar.gz')
    if (ollamaRetired(metadata)) {
      assert(!existsSync(ollamaArchive), 'Setup bundle still carries bundled-ollama.tar.gz although Ollama is retired.')
    } else {
      assert(existsSync(ollamaArchive), 'Setup bundle is missing bundled-ollama.tar.gz.')
    }
    for (const stale of ['bundled-openclaw.tar.gz', 'openclaw-deferred.marker']) {
      assert(
        !existsSync(path.join(setupBundleAssetsPath, stale)),
        `Setup bundle still carries ${stale}; OpenClaw is never bundled. Rebuild with npm run native:dist.`
      )
    }
  }
}

// The OpenClaw lookup only says whether RoachNet's compatibility probe was
// reviewed against the current release; the audit works offline without it.
async function openClawNotice(metadata) {
  try {
    const latest = await fetchLatestNpmPackage('openclaw')
    if (latest && stripVersionPrefix(metadata.openclaw.reviewedVersion) !== stripVersionPrefix(latest)) {
      console.warn(`notice: the OpenClaw compatibility probe was reviewed against ${metadata.openclaw.reviewedVersion}; ${latest} is out. RoachNet does not bundle OpenClaw.`)
    }
  } catch (error) {
    console.warn(`notice: could not look up the latest OpenClaw release (${error instanceof Error ? error.message : error}).`)
  }
}

async function main() {
  assert(existsSync(metadataPath), `Missing runtime freshness metadata at ${metadataPath}.`)
  const metadata = readJson(metadataPath)

  assertBuildScriptMatchesMetadata(metadata)
  assertNodeIsNotShipped(metadata)
  assertRoachClawAgentRewriteMatchesMetadata(metadata)
  assertNativeRuntimeMatchesMetadata(metadata)
  assertDistributionMatchesMetadata(metadata)

  const retired = ollamaRetired(metadata)
  if (!retired) {
    const latestOllama = await fetchLatestOllama()
    assert(latestOllama, 'Could not resolve latest Ollama release.')
    assert(
      stripVersionPrefix(metadata.ollama.bundledVersion) === stripVersionPrefix(latestOllama),
      `Bundled Ollama is stale: metadata has ${metadata.ollama.bundledVersion}, latest ${latestOllama}.`
    )
  }
  await openClawNotice(metadata)

  console.log(
    [
      'Runtime freshness audit passed.',
      `Native Swift runtime (${metadata.nativeRuntime.executable}).`,
      'No Node in either app.',
      retired ? `Ollama retired in ${metadata.ollama.retiredIn} (native RoachInference engine).` : `Ollama ${metadata.ollama.bundledVersion}.`,
      `OpenClaw ${metadata.openclaw.reviewedVersion} (${metadata.openclaw.mode}).`,
      'RoachClaw native agent rewrite.',
      `Hermes reference ${metadata.roachClawAgent.hermesReference.reviewedHead.slice(0, 12)}.`,
    ].join(' ')
  )
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
