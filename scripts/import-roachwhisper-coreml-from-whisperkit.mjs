#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

import { verifyImportedUpstreamFiles } from './lib/roachspeech_pack_digests.mjs'
import { exitForError, fetchUpstreamFile, listUpstreamFiles, readUpstreamInputs, upstreamCacheRoot } from './lib/roachspeech_upstream_fetch.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const defaultRepository = 'argmaxinc/whisperkit-coreml'
const defaultRevision = '0f63a7800b00dd0226abd051b906c246e1907482'
const defaultModel = 'openai_whisper-base.en'
const upstreamInputsPath = path.join(repoRoot, 'docs', 'release-gates', 'roachspeech-upstream-inputs.json')
const tokenizerFiles = [
  'tokenizer.json',
  'tokenizer_config.json',
  'vocab.json',
  'merges.txt',
  'normalizer.json',
  'added_tokens.json',
  'special_tokens_map.json',
  'preprocessor_config.json',
]
const tokenizerModelMap = new Map([
  ['openai_whisper-base.en', 'openai/whisper-base.en'],
  ['openai_whisper-base', 'openai/whisper-base'],
  ['openai_whisper-tiny.en', 'openai/whisper-tiny.en'],
  ['openai_whisper-tiny', 'openai/whisper-tiny'],
  ['openai_whisper-small.en', 'openai/whisper-small.en'],
  ['openai_whisper-small', 'openai/whisper-small'],
])
const tokenizerRevisionMap = new Map([
  ['openai_whisper-base.en', '911407f4214e0e1d82085af863093ec0b66f9cd6'],
])

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

function writeJson(destinationPath, value) {
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true })
  fs.writeFileSync(destinationPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

function packIDForModel(modelName) {
  return `roachwhisper-${modelName.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}-coreml`
}

function tokenizerRepositoryForModel(modelName, args) {
  if (typeof args['tokenizer-repository'] === 'string') {
    return args['tokenizer-repository']
  }
  return tokenizerModelMap.get(modelName) || null
}

function tokenizerRevisionForModel(modelName, args) {
  if (typeof args['tokenizer-revision'] === 'string') {
    return args['tokenizer-revision']
  }
  return tokenizerRevisionMap.get(modelName) || null
}

function targetPathForModelFile(modelFilePath, modelName, outputRoot) {
  const relativePath = modelFilePath.slice(modelName.length + 1)
  if (relativePath.startsWith('AudioEncoder.mlmodelc/')) {
    return path.join(outputRoot, 'RoachWhisper', 'RoachWhisperEncoder.mlmodelc', relativePath.slice('AudioEncoder.mlmodelc/'.length))
  }
  if (relativePath.startsWith('TextDecoder.mlmodelc/')) {
    return path.join(outputRoot, 'RoachWhisper', 'RoachWhisperDecoder.mlmodelc', relativePath.slice('TextDecoder.mlmodelc/'.length))
  }
  if (relativePath.startsWith('MelSpectrogram.mlmodelc/')) {
    return path.join(outputRoot, 'RoachWhisper', 'RoachWhisperMelSpectrogram.mlmodelc', relativePath.slice('MelSpectrogram.mlmodelc/'.length))
  }
  return path.join(outputRoot, 'RoachWhisper', 'Reference', relativePath)
}

/** Fetches and verifies the tokenizer files into the cache. */
async function fetchTokenizerAssets(args, modelName, cacheRoot, manifest) {
  const tokenizerRepository = tokenizerRepositoryForModel(modelName, args)
  const tokenizerRevision = tokenizerRevisionForModel(modelName, args)
  if (!tokenizerRepository || !tokenizerRevision) {
    throw new Error(`No immutable tokenizer source is configured for ${modelName}. Supply --tokenizer-repository and --tokenizer-revision.`)
  }
  const source = { repository: tokenizerRepository, revision: tokenizerRevision }
  const listed = new Map((await listUpstreamFiles(source, { manifest })).map((entry) => [entry.path, entry]))
  const cached = []
  for (const tokenizerFile of tokenizerFiles) {
    const entry = listed.get(tokenizerFile)
    if (!entry) throw new Error(`${tokenizerRepository}@${tokenizerRevision} has no ${tokenizerFile}.`)
    cached.push([tokenizerFile, await fetchUpstreamFile(cacheRoot, source, entry)])
  }
  return { tokenizerRepository, tokenizerRevision, cached }
}

function copyInto(sourcePath, destinationPath) {
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true })
  fs.copyFileSync(sourcePath, destinationPath)
}

async function importWhisperKitCoreML(args) {
  const repository = typeof args.repository === 'string' ? args.repository : defaultRepository
  const modelName = typeof args.model === 'string' ? args.model : defaultModel
  const revision = typeof args.revision === 'string' ? args.revision : defaultRevision
  const packID = typeof args['pack-id'] === 'string' ? args['pack-id'] : packIDForModel(modelName)
  const outputRoot = resolveRepoPath(args.output || `native/macos/Vendor/RoachSpeech/ModelPacks/${packID}`)
  const source = { repository, revision, subpath: modelName }
  const cacheRoot = upstreamCacheRoot(repoRoot)
  const manifest = readUpstreamInputs(upstreamInputsPath)
  const files = await listUpstreamFiles(source, { manifest })

  if (files.length === 0) {
    throw new Error(`No files found for ${repository}/${modelName}@${revision}`)
  }

  // Every file is fetched and verified before the pack is touched.
  const cached = []
  for (const file of files) {
    cached.push([file, await fetchUpstreamFile(cacheRoot, source, file)])
  }
  const tokenizerSource = await fetchTokenizerAssets(args, modelName, cacheRoot, manifest)
  if (args['fetch-only'] === true) {
    console.log(`RoachWhisper: ${files.length + tokenizerSource.cached.length} upstream files verified in ${path.relative(repoRoot, cacheRoot) || cacheRoot}.`)
    return
  }

  fs.rmSync(outputRoot, { recursive: true, force: true })
  fs.mkdirSync(outputRoot, { recursive: true })

  for (const [file, cachedPath] of cached) {
    copyInto(cachedPath, targetPathForModelFile(file.path, modelName, outputRoot))
  }
  for (const [tokenizerFile, cachedPath] of tokenizerSource.cached) {
    copyInto(cachedPath, tokenizerFile === 'tokenizer.json'
      ? path.join(outputRoot, 'RoachWhisper', 'RoachWhisperTokenizer.json')
      : path.join(outputRoot, 'RoachWhisper', 'Reference', 'Tokenizer', tokenizerFile))
  }
  writeJson(path.join(outputRoot, 'RoachWhisper', 'RoachWhisperParity.json'), {
    status: 'staged',
    validated: false,
    note: 'Run RoachWhisper parity fixtures before this pack can ship.',
  })
  writeJson(path.join(outputRoot, 'RoachSpeechPack.json'), {
    packID,
    displayName: args['display-name'] || `RoachWhisper ${modelName}`,
    version: args.version || '0.1.0',
    license: 'MIT',
    kind: 'roachWhisper',
    nativeFormat: 'coreML',
    features: ['speechToText', 'transcriptSidecars', 'lyricExtraction'],
    noNetwork: true,
    noPackagedBinary: true,
    nativeInferenceReady: false,
    parityValidated: false,
    provenance: {
      upstreamProject: 'RoachWares/RoachNet',
      upstreamModelName: modelName,
      sourceFormat: 'Whisper Core ML model bundle',
      conversionCommand: `node scripts/import-roachwhisper-coreml-from-whisperkit.mjs --repository ${repository} --revision ${revision} --model ${modelName} --tokenizer-repository ${tokenizerSource.tokenizerRepository} --tokenizer-revision ${tokenizerSource.tokenizerRevision}`,
      upstreamCommit: revision,
      importedAt: new Date().toISOString(),
      referenceProject: `ggml-org/whisper.cpp native ASR architecture reference; staged Core ML source ${repository}@${revision}; tokenizer source ${tokenizerSource.tokenizerRepository}@${tokenizerSource.tokenizerRevision}`,
    },
  })

  const pinned = await verifyImportedUpstreamFiles(path.join(repoRoot, 'docs', 'release-gates', 'roachspeech-pack-digests.json'), packID, outputRoot)
  if (pinned) console.log(`RoachWhisper: ${pinned} upstream files match the recorded digests.`)
  console.log(`Imported staged RoachWhisper Core ML pack into ${path.relative(repoRoot, outputRoot)}`)
  console.log('This is not release-ready until RoachNet native tokenizer/decode parity is validated.')
}

try {
  const args = parseArgs(process.argv.slice(2))
  if (args['release-ready'] === true) {
    throw new Error('This importer stages third-party Core ML assets only. Use create-roachspeech-native-pack.mjs after RoachNet-owned parity validation.')
  }
  await importWhisperKitCoreML(args)
} catch (error) {
  exitForError(error)
}
