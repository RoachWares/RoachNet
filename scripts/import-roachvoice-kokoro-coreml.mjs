#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const defaultRepository = 'aufklarer/Kokoro-82M-CoreML-INT8'
const defaultRevision = '4bc7df470ea4612a5b6539af16ebf301a027f491'
const defaultPackID = 'roachvoice-kokoro-82m-int8-coreml'

function parseArgs(argv) {
  const args = {}
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (!token.startsWith('--')) continue
    const key = token.slice(2)
    const next = argv[index + 1]
    if (!next || next.startsWith('--')) {
      args[key] = true
    } else {
      args[key] = next
      index += 1
    }
  }
  return args
}

function resolveRepoPath(value) {
  return path.isAbsolute(value) ? value : path.resolve(repoRoot, value)
}

function encodePathSegment(filePath) {
  return filePath.split('/').map(encodeURIComponent).join('/')
}

async function fetchJson(url) {
  const response = await fetch(url, {
    headers: {
      'User-Agent': 'RoachNet-RoachVoice-Importer/1.0',
    },
  })
  if (!response.ok) {
    throw new Error(`Request failed ${response.status}: ${url}`)
  }
  return response.json()
}

async function downloadFile(url, destinationPath) {
  const response = await fetch(url, {
    headers: {
      'User-Agent': 'RoachNet-RoachVoice-Importer/1.0',
    },
  })
  if (!response.ok) {
    throw new Error(`Download failed ${response.status}: ${url}`)
  }
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true })
  fs.writeFileSync(destinationPath, Buffer.from(await response.arrayBuffer()))
}

function targetPathForKokoroFile(sourcePath, outputRoot) {
  if (sourcePath.startsWith('kokoro_5s.mlmodelc/')) {
    return path.join(outputRoot, 'RoachVoice', 'RoachVoiceNarrator.mlmodelc', sourcePath.slice('kokoro_5s.mlmodelc/'.length))
  }
  if (sourcePath.startsWith('G2PEncoder.mlmodelc/')) {
    return path.join(outputRoot, 'RoachVoice', 'RoachVoiceG2PEncoder.mlmodelc', sourcePath.slice('G2PEncoder.mlmodelc/'.length))
  }
  if (sourcePath.startsWith('G2PDecoder.mlmodelc/')) {
    return path.join(outputRoot, 'RoachVoice', 'RoachVoiceG2PDecoder.mlmodelc', sourcePath.slice('G2PDecoder.mlmodelc/'.length))
  }
  if (sourcePath.startsWith('voices/')) {
    return path.join(outputRoot, 'RoachVoice', 'Voices', sourcePath.slice('voices/'.length))
  }
  if (['g2p_vocab.json', 'vocab_index.json', 'pipeline_config.json', 'us_gold.json', 'us_silver.json'].includes(sourcePath)) {
    return path.join(outputRoot, 'RoachVoice', 'Reference', sourcePath)
  }
  return path.join(outputRoot, 'RoachVoice', 'Reference', sourcePath)
}

function writeJson(destinationPath, value) {
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true })
  fs.writeFileSync(destinationPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

async function importKokoro(args) {
  const repository = typeof args.repository === 'string' ? args.repository : defaultRepository
  const revision = typeof args.revision === 'string' ? args.revision : defaultRevision
  const packID = typeof args['pack-id'] === 'string' ? args['pack-id'] : defaultPackID
  const outputRoot = resolveRepoPath(args.output || `native/macos/Vendor/RoachSpeech/ModelPacks/${packID}`)
  const treeURL = `https://huggingface.co/api/models/${repository}/tree/${revision}?recursive=1`
  const files = (await fetchJson(treeURL)).filter((entry) => entry.type === 'file')
  const wanted = files.filter((entry) =>
    entry.path.startsWith('kokoro_5s.mlmodelc/') ||
    entry.path.startsWith('G2PEncoder.mlmodelc/') ||
    entry.path.startsWith('G2PDecoder.mlmodelc/') ||
    entry.path.startsWith('voices/') ||
    ['LICENSE', 'README.md', 'g2p_vocab.json', 'vocab_index.json', 'pipeline_config.json', 'us_gold.json', 'us_silver.json'].includes(entry.path)
  )

  if (wanted.length === 0) {
    throw new Error(`No Kokoro Core ML files found for ${repository}@${revision}`)
  }

  fs.rmSync(outputRoot, { recursive: true, force: true })
  fs.mkdirSync(outputRoot, { recursive: true })

  for (const file of wanted) {
    const sourceURL = `https://huggingface.co/${repository}/resolve/${revision}/${encodePathSegment(file.path)}`
    await downloadFile(sourceURL, targetPathForKokoroFile(file.path, outputRoot))
  }

  writeJson(path.join(outputRoot, 'RoachVoice', 'RoachVoiceEmbedding.json'), {
    type: 'kokoro-voice-table',
    source: repository,
    defaultVoice: args.voice || 'af_heart',
    voicesPath: 'RoachVoice/Voices',
    localOnly: true,
    note: 'Kokoro voice embeddings are local JSON voices. User custom voices remain separate RoachVoice projects until a cloning pack is validated.',
  })

  writeJson(path.join(outputRoot, 'RoachSpeechPack.json'), {
    packID,
    displayName: args['display-name'] || 'RoachVoice Kokoro 82M INT8',
    version: args.version || '1.0.6',
    license: 'Apache-2.0',
    kind: 'roachVoice',
    nativeFormat: 'coreML',
    features: ['customVoiceSynthesis'],
    noNetwork: true,
    noPackagedBinary: true,
    nativeInferenceReady: true,
    parityValidated: false,
    provenance: {
      upstreamProject: 'RoachWares/RoachNet',
      upstreamModelName: 'RoachVoice Kokoro 82M INT8',
      sourceFormat: 'Kokoro 82M Core ML INT8 pack',
      conversionCommand: `node scripts/import-roachvoice-kokoro-coreml.mjs --repository ${repository} --revision ${revision}`,
      upstreamCommit: revision,
      importedAt: new Date().toISOString(),
      referenceProject: `${repository}; base model hexgrad/Kokoro-82M Apache-2.0`,
    },
  })

  console.log(`Imported RoachVoice Kokoro Core ML pack into ${path.relative(repoRoot, outputRoot)}`)
}

try {
  const args = parseArgs(process.argv.slice(2))
  await importKokoro(args)
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exit(1)
}
