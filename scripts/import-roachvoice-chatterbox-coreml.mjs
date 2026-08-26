#!/usr/bin/env node

import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')
const defaultRepository = 'yepher/screen-cut-pro-tts-coreml'
const defaultRevision = 'f4fae0751b59970c170ca8d40cbf0c53dc20ad37'
const defaultPackID = 'roachvoice-chatterbox-coreml'

const modelPackages = new Map([
  ['t3_text_emb.mlpackage', 'RoachVoice/RoachVoiceEmbedTokens.mlmodelc'],
  ['t3_text_pos_emb.mlpackage', 'RoachVoice/Reference/RoachVoiceTextPositionEmbedding.mlmodelc'],
  ['t3_speech_emb.mlpackage', 'RoachVoice/Reference/RoachVoiceSpeechTokenEmbedding.mlmodelc'],
  ['t3_speech_pos_emb.mlpackage', 'RoachVoice/Reference/RoachVoiceSpeechPositionEmbedding.mlmodelc'],
  ['t3_cond_enc.mlpackage', 'RoachVoice/Reference/RoachVoiceConditionEncoder.mlmodelc'],
  ['t3_tfmr.mlpackage', 'RoachVoice/RoachVoiceLanguageModel.mlmodelc'],
  ['t3_speech_head.mlpackage', 'RoachVoice/Reference/RoachVoiceSpeechHead.mlmodelc'],
  ['s3_tokenizer.mlpackage', 'RoachVoice/Reference/RoachVoiceSpeechTokenizer.mlmodelc'],
  ['voice_encoder.mlpackage', 'RoachVoice/RoachVoiceSpeechEncoder.mlmodelc'],
  ['campplus.mlpackage', 'RoachVoice/Reference/RoachVoiceCAMPPlusSpeakerEncoder.mlmodelc'],
  ['flow_encoder.mlpackage', 'RoachVoice/Reference/RoachVoiceFlowEncoder.mlmodelc'],
  ['flow_estimator.mlpackage', 'RoachVoice/RoachVoiceConditionalDecoder.mlmodelc'],
  ['mel2wav.mlpackage', 'RoachVoice/Reference/RoachVoiceMelVocoder.mlmodelc'],
])

const referenceFiles = new Set([
  'LICENSE',
  'NOTICE',
  'README.md',
  'metadata.json',
  'tokenizer.json',
  'default_t3_speaker_emb.bin',
  'default_t3_cond_prompt_tokens.bin',
  'default_flow_prompt_token.bin',
  'default_flow_prompt_feat.bin',
  'default_flow_speaker_embedding.bin',
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

function encodePathSegment(filePath) {
  return filePath.split('/').map(encodeURIComponent).join('/')
}

async function fetchJson(url) {
  const response = await fetch(url, {
    headers: {
      'User-Agent': 'RoachNet-RoachVoice-Chatterbox-Importer/1.0',
    },
  })
  if (!response.ok) {
    throw new Error(`Request failed ${response.status}: ${url}`)
  }
  return response.json()
}

async function downloadFile(url, destinationPath) {
  if (fs.existsSync(destinationPath) && fs.statSync(destinationPath).size > 0) {
    return
  }
  const response = await fetch(url, {
    headers: {
      'User-Agent': 'RoachNet-RoachVoice-Chatterbox-Importer/1.0',
    },
  })
  if (!response.ok) {
    throw new Error(`Download failed ${response.status}: ${url}`)
  }
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true })
  fs.writeFileSync(destinationPath, Buffer.from(await response.arrayBuffer()))
}

function copyFile(sourcePath, destinationPath) {
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true })
  fs.copyFileSync(sourcePath, destinationPath)
}

function writeJson(destinationPath, value) {
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true })
  fs.writeFileSync(destinationPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
}

function requireCoreMLCompiler() {
  const result = spawnSync('xcrun', ['--find', 'coremlcompiler'], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  if (result.status !== 0 || result.error) {
    const detail = [result.stdout, result.stderr, result.error?.message]
      .filter((value) => typeof value === 'string' && value.trim())
      .join('\n')
    throw new Error([
      'RoachVoice Chatterbox import requires Xcode Command Line Tools with coremlcompiler.',
      'Run this command on supported macOS with Xcode selected: xcode-select --switch /Applications/Xcode.app/Contents/Developer',
      detail,
    ].filter(Boolean).join('\n'))
  }
}

function runCoreMLCompiler(packagePath, outputDirectory, destinationPath) {
  fs.rmSync(outputDirectory, { recursive: true, force: true })
  fs.mkdirSync(outputDirectory, { recursive: true })

  const result = spawnSync(
    'xcrun',
    [
      'coremlcompiler',
      'compile',
      packagePath,
      outputDirectory,
      '--platform',
      'macOS',
      '--deployment-target',
      '14.0',
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8',
    }
  )
  if (result.status !== 0) {
    throw new Error(
      [
        `coremlcompiler failed for ${path.relative(repoRoot, packagePath)}`,
        typeof result.stdout === 'string' ? result.stdout.trim() : '',
        typeof result.stderr === 'string' ? result.stderr.trim() : '',
        result.error?.message || '',
      ].filter(Boolean).join('\n')
    )
  }

  const compiledBundles = fs.readdirSync(outputDirectory, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.endsWith('.mlmodelc'))
  if (compiledBundles.length !== 1) {
    throw new Error(`Expected one compiled bundle in ${outputDirectory}, found ${compiledBundles.length}`)
  }

  fs.rmSync(destinationPath, { recursive: true, force: true })
  fs.mkdirSync(path.dirname(destinationPath), { recursive: true })
  fs.renameSync(path.join(outputDirectory, compiledBundles[0].name), destinationPath)
}

function targetPathForReferenceFile(sourcePath, outputRoot) {
  if (sourcePath === 'tokenizer.json') {
    return path.join(outputRoot, 'RoachVoice', 'RoachVoiceTokenizer.json')
  }
  if (sourcePath.endsWith('.bin')) {
    return path.join(outputRoot, 'RoachVoice', 'Reference', sourcePath)
  }
  return path.join(outputRoot, 'RoachVoice', 'Reference', sourcePath)
}

async function downloadPackage(repository, revision, packageName, files, stagingRoot) {
  const packageFiles = files.filter((entry) => entry.path.startsWith(`${packageName}/`))
  if (packageFiles.length === 0) {
    throw new Error(`Missing ${packageName} in ${repository}@${revision}`)
  }
  const packageRoot = path.join(stagingRoot, packageName)
  for (const file of packageFiles) {
    const sourceURL = `https://huggingface.co/${repository}/resolve/${revision}/${encodePathSegment(file.path)}`
    const destination = path.join(stagingRoot, file.path)
    await downloadFile(sourceURL, destination)
  }
  return packageRoot
}

async function importChatterbox(args) {
  const repository = typeof args.repository === 'string' ? args.repository : defaultRepository
  const revision = typeof args.revision === 'string' ? args.revision : defaultRevision
  const packID = typeof args['pack-id'] === 'string' ? args['pack-id'] : defaultPackID
  const outputRoot = resolveRepoPath(args.output || `native/macos/Vendor/RoachSpeech/ModelPacks/${packID}`)
  const stagingRoot = resolveRepoPath(args.staging || `.tmp/roachvoice-chatterbox-coreml/${revision}`)
  const compileRoot = path.join(stagingRoot, '.compiled')
  requireCoreMLCompiler()
  const treeURL = `https://huggingface.co/api/models/${repository}/tree/${revision}?recursive=1`
  const files = (await fetchJson(treeURL)).filter((entry) => entry.type === 'file')

  if (files.length === 0) {
    throw new Error(`No Core ML files found for ${repository}@${revision}`)
  }

  fs.rmSync(outputRoot, { recursive: true, force: true })
  fs.mkdirSync(outputRoot, { recursive: true })
  fs.mkdirSync(stagingRoot, { recursive: true })

  for (const [packageName, relativeDestination] of modelPackages) {
    const packageRoot = await downloadPackage(repository, revision, packageName, files, stagingRoot)
    const destination = path.join(outputRoot, relativeDestination)
    runCoreMLCompiler(packageRoot, path.join(compileRoot, packageName), destination)
    console.log(`Compiled ${packageName} -> ${path.relative(repoRoot, destination)}`)
  }

  for (const file of files.filter((entry) => referenceFiles.has(entry.path))) {
    const sourceURL = `https://huggingface.co/${repository}/resolve/${revision}/${encodePathSegment(file.path)}`
    const stagingPath = path.join(stagingRoot, file.path)
    await downloadFile(sourceURL, stagingPath)
    copyFile(stagingPath, targetPathForReferenceFile(file.path, outputRoot))
  }

  writeJson(path.join(outputRoot, 'RoachVoice', 'RoachVoiceEmbedding.json'), {
    type: 'chatterbox-reference-voice',
    source: repository,
    localOnly: true,
    voiceCloning: true,
    defaultEmbeddings: {
      t3SpeakerEmbedding: 'RoachVoice/Reference/default_t3_speaker_emb.bin',
      t3ConditionPromptTokens: 'RoachVoice/Reference/default_t3_cond_prompt_tokens.bin',
      flowPromptToken: 'RoachVoice/Reference/default_flow_prompt_token.bin',
      flowPromptFeature: 'RoachVoice/Reference/default_flow_prompt_feat.bin',
      flowSpeakerEmbedding: 'RoachVoice/Reference/default_flow_speaker_embedding.bin',
    },
    note: 'The bundled reference voice is local. User voice projects replace these embeddings with microphone or imported-file samples.',
  })

  writeJson(path.join(outputRoot, 'RoachSpeechPack.json'), {
    packID,
    displayName: args['display-name'] || 'RoachVoice Chatterbox Core ML',
    version: args.version || '1.0.6',
    license: 'MIT',
    kind: 'roachVoice',
    nativeFormat: 'coreML',
    features: ['customVoiceSynthesis', 'voiceCloning'],
    noNetwork: true,
    noPackagedBinary: true,
    nativeInferenceReady: true,
    parityValidated: false,
    provenance: {
      upstreamProject: 'RoachWares/RoachNet',
      upstreamModelName: 'RoachVoice Chatterbox Core ML',
      sourceFormat: 'Chatterbox TTS Core ML component pack',
      conversionCommand: `node scripts/import-roachvoice-chatterbox-coreml.mjs --repository ${repository} --revision ${revision}`,
      upstreamCommit: revision,
      importedAt: new Date().toISOString(),
      referenceProject: `${repository}; base model ResembleAI/chatterbox MIT; Chatterbox-Turbo target evaluated from ResembleAI/chatterbox-turbo and ResembleAI/chatterbox-turbo-ONNX`,
    },
  })

  console.log(`Imported RoachVoice Chatterbox Core ML pack into ${path.relative(repoRoot, outputRoot)}`)
}

try {
  const args = parseArgs(process.argv.slice(2))
  if (args['check-compiler'] === true) {
    requireCoreMLCompiler()
    console.log('coremlcompiler is available.')
  } else {
    await importChatterbox(args)
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exit(1)
}
