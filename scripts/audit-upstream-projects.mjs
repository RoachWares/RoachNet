#!/usr/bin/env node

import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { requestHttp } from './lib/roachnet_http.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const metadataPath = path.join(repoRoot, 'docs', 'release-gates', 'upstream-projects.json')

function assert(condition, message) {
  if (!condition) {
    throw new Error(message)
  }
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, 'utf8'))
}

async function fetchJson(url, headers = {}) {
  const token = process.env.GITHUB_TOKEN?.trim() || process.env.GH_TOKEN?.trim() || ''
  const authHeaders = token && String(url).startsWith('https://api.github.com/')
    ? { authorization: `Bearer ${token}` }
    : {}
  const response = await requestHttp(url, {
    headers: {
      accept: 'application/json',
      'user-agent': 'RoachNet-Upstream-Project-Audit',
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

async function fetchGitHubRelease(project) {
  const release = await fetchJson(`https://api.github.com/repos/${project.repository}/releases/latest`)
  const head = await fetchJson(`https://api.github.com/repos/${project.repository}/commits/HEAD`)
  return {
    tag: release.tag_name,
    name: release.name,
    publishedAt: release.published_at,
    observedHead: head.sha,
  }
}

async function fetchGitLabRelease(project) {
  const encodedProject = encodeURIComponent(project.project)
  const releases = await fetchJson(`https://gitlab.com/api/v4/projects/${encodedProject}/releases?per_page=1`)
  const release = Array.isArray(releases) ? releases[0] : null
  return {
    tag: release?.tag_name,
    name: release?.name,
    publishedAt: release?.released_at,
    commit: release?.commit?.id,
  }
}

async function fetchHuggingFaceModel(project) {
  const model = await fetchJson(`https://huggingface.co/api/models/${project.repository}`)
  return {
    sha: model.sha,
    lastModified: model.lastModified,
    license: model.cardData?.license,
  }
}

function releaseTimestampSeconds(value) {
  const timestamp = Date.parse(value)
  return Number.isNaN(timestamp) ? value : Math.floor(timestamp / 1_000)
}

export function compareRelease(projectId, expected, actual) {
  for (const field of ['tag', 'name']) {
    assert(
      expected[field] === actual[field],
      `${projectId} upstream release drift: metadata ${field}=${expected[field] || 'missing'}, latest ${field}=${actual[field] || 'missing'}`
    )
  }

  assert(
    releaseTimestampSeconds(expected.publishedAt) === releaseTimestampSeconds(actual.publishedAt),
    `${projectId} upstream release drift: metadata publishedAt=${expected.publishedAt || 'missing'}, latest publishedAt=${actual.publishedAt || 'missing'}`
  )

  if (expected.commit || actual.commit) {
    assert(
      expected.commit === actual.commit,
      `${projectId} upstream release drift: metadata commit=${expected.commit || 'missing'}, latest commit=${actual.commit || 'missing'}`
    )
  }
}

export function isDesignReference(project) {
  return (project?.kind || 'design-reference') === 'design-reference'
}

// A design reference must never become a dependency: no package entry, no
// vendored source tree, no Swift package.
function assertReferencesAreNotVendored(projects) {
  const packageJson = readJson(path.join(repoRoot, 'package.json'))
  const declared = new Set(Object.keys({
    ...(packageJson.dependencies || {}),
    ...(packageJson.optionalDependencies || {}),
  }).map((name) => name.toLowerCase()))
  const swiftManifest = readFileSync(path.join(repoRoot, 'native', 'macos', 'Package.swift'), 'utf8')
  for (const [projectId, project] of projects) {
    if (!isDesignReference(project)) continue
    const repoName = String(project.repository || project.project || projectId).split('/').pop().toLowerCase()
    assert(!declared.has(repoName), `${projectId} is a design reference but package.json depends on ${repoName}.`)
    assert(
      !swiftManifest.toLowerCase().includes(`/${repoName}`),
      `${projectId} is a design reference but native/macos/Package.swift references it.`
    )
    for (const root of ['vendor', 'third_party', 'external', path.join('native', 'macos', 'Vendor')]) {
      assert(
        !existsSync(path.join(repoRoot, root, repoName)),
        `${projectId} is a design reference but its source is vendored at ${path.join(root, repoName)}.`
      )
    }
  }
}

async function main() {
  assert(existsSync(metadataPath), `Missing upstream project metadata at ${metadataPath}.`)
  const metadata = readJson(metadataPath)
  const projects = Object.entries(metadata.projects || {})
  assert(projects.length > 0, 'Upstream project metadata must include at least one project.')

  const branchMovements = []
  const drifts = []
  const referenceNotices = []

  assertReferencesAreNotVendored(projects)

  for (const [projectId, project] of projects) {
    try {
      const expected = project.latestRelease || {}
      if (project.provider === 'huggingface') {
        const latest = await fetchHuggingFaceModel(project)
        const expected = project.latestModel || {}
        for (const field of ['sha', 'lastModified', 'license']) {
          assert(
            expected[field] === latest[field],
            `${projectId} upstream model drift: metadata ${field}=${expected[field] || 'missing'}, latest ${field}=${latest[field] || 'missing'}`
          )
        }
        continue
      }

      const latest = project.provider === 'gitlab'
        ? await fetchGitLabRelease(project)
        : await fetchGitHubRelease(project)

      compareRelease(projectId, expected, latest)

      if (expected.observedHead && latest.observedHead && expected.observedHead !== latest.observedHead) {
        branchMovements.push(
          `${projectId} default branch moved since audit metadata: ${expected.observedHead.slice(0, 12)} -> ${latest.observedHead.slice(0, 12)}`
        )
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      // Design references are studied, not shipped: drift is review context only.
      if (isDesignReference(project)) {
        referenceNotices.push(message)
      } else {
        drifts.push(message)
      }
    }
  }

  for (const notice of referenceNotices) {
    console.log(`Design reference to review (non-blocking): ${notice}`)
  }
  assert(drifts.length === 0, drifts.join('\n'))

  if (branchMovements.length > 0 && process.env.ROACHNET_UPSTREAM_VERBOSE === '1') {
    for (const movement of branchMovements) {
      console.log(`Upstream audit context: ${movement}`)
    }
  }

  const branchContext = branchMovements.length > 0
    ? ` Default-branch movement observed for ${branchMovements.length} project${branchMovements.length === 1 ? '' : 's'}; stable release metadata is unchanged and remains the blocking gate.`
    : ''
  console.log(`Upstream project audit passed for ${projects.length} references (${referenceNotices.length} design reference${referenceNotices.length === 1 ? '' : 's'} to review).${branchContext}`)
}

if (process.argv[1] && path.resolve(process.argv[1]) === __filename) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error)
    process.exitCode = 1
  })
}
