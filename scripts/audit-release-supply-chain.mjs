#!/usr/bin/env node

import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import process from 'node:process'

function parseArgs(argv) {
  const values = {}
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!key?.startsWith('--') || !value) throw new Error(`Invalid argument near ${key || '<end>'}`)
    values[key.slice(2)] = value
  }
  return values
}

function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, 'utf8'))
}

async function queryOsv(purl) {
  const response = await fetch('https://api.osv.dev/v1/query', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'user-agent': 'RoachNet-Release-Audit/1.0' },
    body: JSON.stringify({ package: { purl } }),
    signal: AbortSignal.timeout(30_000),
  })
  if (!response.ok) throw new Error(`OSV query failed for ${purl}: ${response.status}`)
  const result = await response.json()
  return Array.isArray(result.vulns) ? result.vulns : []
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  for (const key of ['inventory', 'sbom', 'candidate-sha', 'tag', 'dmg-sha256']) {
    if (!args[key]) throw new Error(`Missing --${key}`)
  }
  if (!existsSync(args.inventory) || !existsSync(args.sbom)) throw new Error('Supply-chain files are missing.')

  const inventory = readJson(args.inventory)
  const sbom = readJson(args.sbom)
  const failures = []
  if (inventory.schema !== 'org.roachnet.release-supply-chain.v1') failures.push('Unknown inventory schema.')
  if (inventory.candidateSha !== args['candidate-sha']) failures.push('Inventory candidate SHA mismatch.')
  if (inventory.tag !== args.tag) failures.push('Inventory tag mismatch.')
  if (inventory.dmg?.sha256 !== args['dmg-sha256']) failures.push('Inventory DMG checksum mismatch.')
  if (sbom.spdxVersion !== 'SPDX-2.3') failures.push('SBOM is not SPDX 2.3.')

  const componentNames = new Set(inventory.components?.map((component) => component.name) || [])
  for (const required of ['RoachNet', 'Node.js', 'Ollama', 'OpenClaw']) {
    if (!componentNames.has(required)) failures.push(`Missing ${required} supply-chain disposition.`)
  }
  const openClaw = inventory.components?.find((component) => component.name === 'OpenClaw')
  if (openClaw?.version !== 'not-bundled') failures.push('OpenClaw must be explicitly absent from this candidate artifact.')

  for (const component of inventory.components || []) {
    if (!component.license || component.license === 'NOASSERTION') {
      failures.push(`Component ${component.name} lacks a reviewed distribution license.`)
    }
    if (!component.source || component.source === 'NOASSERTION') {
      failures.push(`Component ${component.name} lacks a pinned source.`)
    }
    if (['Node.js', 'Ollama'].includes(component.name) && component.version !== 'not-bundled' && !/^[a-f0-9]{64}$/i.test(component.sourceSha256 || '')) {
      failures.push(`Component ${component.name} lacks a source artifact checksum.`)
    }
  }

  for (const file of inventory.files || []) {
    if (!file.path || !Number.isSafeInteger(file.bytes) || !/^[a-f0-9]{64}$/i.test(file.sha256 || '')) {
      failures.push(`Invalid mounted-artifact file record: ${file.path || '<missing path>'}`)
      break
    }
    if (/\/(?:admin|node_modules\/\.cache|storage|\.env)(?:\/|$)/i.test(`/${file.path}`)) {
      failures.push(`Forbidden legacy/local payload in mounted artifact: ${file.path}`)
      break
    }
  }

  const vulnerabilityRecord = {
    schema: 'org.roachnet.release-vulnerability-scan.v1',
    candidateSha: args['candidate-sha'],
    tag: args.tag,
    scannedAt: new Date().toISOString(),
    scanner: args.online === 'true' ? 'OSV API v1/query' : 'not-run',
    results: [],
  }
  const vulnerabilityPath = path.join(path.dirname(args.inventory), 'vulnerability-scan.json')
  if (args.online === 'true') {
    const ollamaVersion = inventory.components.find((entry) => entry.name === 'Ollama')?.version
    const purls = [
      `pkg:github/nodejs/node@v${String(inventory.components.find((entry) => entry.name === 'Node.js')?.version || '').replace(/^v/, '')}`,
      ...(ollamaVersion && ollamaVersion !== 'not-bundled' ? [`pkg:github/ollama/ollama@v${String(ollamaVersion).replace(/^v/, '')}`] : []),
    ]
    for (const purl of purls) {
      const vulnerabilities = await queryOsv(purl)
      vulnerabilityRecord.results.push({ purl, vulnerabilities: vulnerabilities.map((entry) => entry.id) })
      if (vulnerabilities.length > 0) failures.push(`${purl} has known OSV records: ${vulnerabilities.map((entry) => entry.id).join(', ')}`)
    }
    writeFileSync(vulnerabilityPath, `${JSON.stringify(vulnerabilityRecord, null, 2)}\n`)
  } else if (args.online === 'verify') {
    if (!existsSync(vulnerabilityPath)) {
      failures.push('Candidate-bound vulnerability scan evidence is missing.')
    } else {
      const stagedScan = readJson(vulnerabilityPath)
      if (stagedScan.candidateSha !== args['candidate-sha'] || stagedScan.tag !== args.tag || stagedScan.scanner !== 'OSV API v1/query') {
        failures.push('Candidate-bound vulnerability scan identity is invalid.')
      }
      for (const result of stagedScan.results || []) {
        if (!Array.isArray(result.vulnerabilities) || result.vulnerabilities.length > 0) {
          failures.push(`${result.purl || 'Unknown component'} has staged vulnerability findings.`)
        }
      }
      const expectedScans = inventory.components?.find((entry) => entry.name === 'Ollama')?.version === 'not-bundled' ? 1 : 2
      if (!Array.isArray(stagedScan.results) || stagedScan.results.length < expectedScans) {
        failures.push('Candidate-bound vulnerability scan does not cover every bundled runtime.')
      }
    }
  } else {
    failures.push('Candidate-bound online vulnerability scan was not run or verified.')
  }

  if (failures.length > 0) {
    throw new Error(`Release supply-chain audit failed:\n- ${failures.join('\n- ')}`)
  }
  console.log(`Release supply-chain audit passed for ${inventory.files.length} mounted-artifact files.`)
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
