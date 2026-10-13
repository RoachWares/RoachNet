#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const repoRoot = path.resolve(__dirname, '..')

const failures = []
const staleNotices = []

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(repoRoot, relativePath), 'utf8'))
}

function readText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8')
}

function listFiles(relativePath, predicate = () => true) {
  const absoluteRoot = path.join(repoRoot, relativePath)
  const files = []
  for (const entry of fs.readdirSync(absoluteRoot, { withFileTypes: true })) {
    const entryRelativePath = path.join(relativePath, entry.name)
    if (entry.isDirectory()) {
      files.push(...listFiles(entryRelativePath, predicate))
    } else if (predicate(entryRelativePath)) {
      files.push(entryRelativePath)
    }
  }
  return files
}

function sortedObject(value) {
  return Object.fromEntries(Object.entries(value || {}).sort(([left], [right]) => left.localeCompare(right)))
}

function requireMatchingDependencySection(packageJson, lockRoot, section, label) {
  const manifestSection = sortedObject(packageJson[section])
  const lockSection = sortedObject(lockRoot[section])
  if (JSON.stringify(manifestSection) !== JSON.stringify(lockSection)) {
    failures.push(`${label} ${section} drift between package.json and package-lock.json`)
  }
}

function requirePackageLockMatchesManifest(packagePath, lockPath, label) {
  const packageJson = readJson(packagePath)
  const packageLock = readJson(lockPath)
  const lockRoot = packageLock.packages?.['']
  if (!lockRoot) {
    failures.push(`${label} package-lock.json is missing packages[""] metadata`)
    return
  }

  if (lockRoot.name !== packageJson.name) {
    failures.push(`${label} package-lock name ${lockRoot.name} does not match ${packageJson.name}`)
  }
  if (lockRoot.version !== packageJson.version) {
    failures.push(`${label} package-lock version ${lockRoot.version} does not match ${packageJson.version}`)
  }

  for (const section of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
    requireMatchingDependencySection(packageJson, lockRoot, section, label)
  }
}

function requireFile(relativePath, label) {
  if (!fs.existsSync(path.join(repoRoot, relativePath))) {
    failures.push(`${label} is missing: ${relativePath}`)
  }
}

function requireNoKeys(object, keys, label) {
  const present = keys.filter((key) => Object.prototype.hasOwnProperty.call(object || {}, key))
  if (present.length > 0) {
    failures.push(`${label} still includes ${present.join(', ')}`)
  }
}

function requireNoPackagePattern(packageJson, pattern, label) {
  for (const section of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const name of Object.keys(packageJson[section] || {})) {
      if (pattern.test(name)) {
        failures.push(`${label} ${section} still includes ${name}`)
      }
    }
  }
}

function requireNodeEngine(packageJson, label, expectedNodeRange) {
  if (packageJson.engines?.node !== expectedNodeRange) {
    failures.push(`${label} package must declare engines.node "${expectedNodeRange}"`)
  }
  if (packageJson.engines?.npm !== '>=10') {
    failures.push(`${label} package must declare engines.npm ">=10"`)
  }
}

// The shipping runtime is the dependency-free Swift helper (roachnet-runtime).
function requireNativeSwiftRuntime() {
  const runtimeRoots = ['native/macos/Sources/RoachNetRuntime', 'native/macos/Sources/RoachNetRuntimeHost', 'native/macos/Sources/RoachInference', 'native/macos/Sources/RoachInferenceTool']
  for (const relativePath of [
    'native/macos/Sources/RoachNetRuntime/RuntimeServer.swift',
    'native/macos/Sources/RoachNetRuntime/Router.swift',
    'native/macos/Sources/RoachNetRuntime/SetupEngine.swift',
    'native/macos/Sources/RoachNetRuntime/SetupPlatform.swift',
    'native/macos/Sources/RoachNetRuntime/RoachTailHostname.swift',
    'native/macos/Sources/RoachNetRuntimeHost/main.swift',
    'native/macos/Sources/RoachInference/GGUF.swift',
    'native/macos/Sources/RoachInference/InferenceEngine.swift',
    'native/macos/Sources/RoachNetRuntime/NativeModelServer.swift',
  ]) {
    requireFile(relativePath, 'native Swift runtime')
  }
  // Metal is allowed only for RoachInference's hand-written kernels; no ML frameworks
  // (Accelerate, Metal Performance Shaders, Core ML, MLX) and no third-party code.
  // dnssd is the system DNS Service Discovery library (libSystem), for RoachNet Cluster's Bonjour.
  // Compression is the system DEFLATE library (libcompression); RoachNet's own ZIP reader
  // inflates pack archives with it on macOS.
  const allowedModules = new Set(['Foundation', 'FoundationNetworking', 'Darwin', 'Glibc', 'CryptoKit', 'Dispatch', 'Metal', 'dnssd', 'Compression', 'RoachNetRuntime', 'RoachInference'])
  for (const root of runtimeRoots) {
    for (const relativePath of listFiles(root, (candidate) => candidate.endsWith('.swift'))) {
      const source = readText(relativePath)
      for (const match of source.matchAll(/^\s*(?:@\w+\s+)*import\s+(?:struct\s+|class\s+|enum\s+|func\s+)?([A-Za-z_][A-Za-z0-9_]*)/gm)) {
        if (!allowedModules.has(match[1])) {
          failures.push(`${relativePath} imports ${match[1]}; the native runtime must stay on system frameworks only`)
        }
      }
    }
  }
  const packageManifest = readText('native/macos/Package.swift')
  if (/\.package\s*\(/.test(packageManifest)) {
    failures.push('native/macos/Package.swift must not declare third-party package dependencies')
  }
  const serverSource = readText('native/macos/Sources/RoachNetRuntime/RuntimeServer.swift')
  if (!/static func normalizeLoopbackHost/.test(serverSource) || !/only binds to loopback hosts/.test(serverSource)) {
    failures.push('native Swift runtime must refuse non-loopback bind hosts')
  }
  const companionSource = readText('native/macos/Sources/RoachNetRuntime/RuntimeServer.swift')
  if (!/must bind only to a loopback address/.test(companionSource)) {
    failures.push('native companion bridge must bind only to loopback')
  }
  const hostSource = readText('native/macos/Sources/RoachNetRuntimeHost/main.swift')
  for (const mode of ['--setup', '--install', '--provision-alias', '--stop', '--version']) {
    if (!hostSource.includes(`"${mode}"`)) {
      failures.push(`roachnet-runtime must support ${mode} so setup, Homebrew and scripted installs need no Node`)
    }
  }
  const setupSource = readText('native/macos/Sources/RoachNetRuntime/SetupEngine.swift')
  for (const [pattern, message] of [
    [/hardwareIsAppleSilicon/, 'native setup must refuse non-Apple-Silicon hardware'],
    [/smokeTestRuntime/, 'native setup must smoke-test the staged runtime before swapping it in'],
    [/finalizeInstallRoot/, 'native setup must promote installs through the staged root swap'],
    [/provisionLocalAlias/, 'native setup must provision the RoachTail local alias'],
  ]) {
    if (!pattern.test(setupSource)) failures.push(message)
  }
  const coreSource = readText('native/macos/Sources/RoachNetCore/ManagedAppRuntime.swift')
  if (!/nativeRuntimeBinary\(\)/.test(coreSource)) {
    failures.push('ManagedAppRuntime must launch the native runtime helper')
  }
  // Nothing in the apps may look for Node, switch to it or start it (ROA-78).
  for (const relativePath of listFiles('native/macos/Sources', (candidate) => candidate.endsWith('.swift'))) {
    const source = readText(relativePath)
    for (const [pattern, what] of [
      [/preferred(?:Portable)?NodeBinary|embeddedNode(?:Root|Binary|BinDirectory)|isPortableNodeBinary/, 'looks for a Node binary'],
      [/ROACHNET_FORCE_NODE_RUNTIME|node-compat|ROACHNET_REQUIRE_PORTABLE_NODE"\]\s*=/, 'can switch RoachNet to a Node runtime'],
      [/RoachNetSource(?:\.tar\.gz)?"/, 'reads RoachNet source carried in a bundle'],
    ]) {
      if (pattern.test(source)) failures.push(`${relativePath} ${what}; RoachNet runs only its Swift runtime`)
    }
  }
}

function requireNoThirdPartyImports(relativePaths, label) {
  const importPattern =
    /\bfrom\s+['"]([^'"]+)['"]|\brequire\(\s*['"]([^'"]+)['"]\s*\)|\bimport\(\s*['"]([^'"]+)['"]\s*\)/g
  for (const relativePath of relativePaths) {
    const source = readText(relativePath)
    for (const match of source.matchAll(importPattern)) {
      const specifier = match[1] || match[2] || match[3] || ''
      if (!specifier.startsWith('node:') && !specifier.startsWith('.') && !specifier.startsWith('/') && !specifier.startsWith('#')) {
        failures.push(`${label} imports third-party module ${specifier} in ${relativePath}`)
      }
    }
  }
}

function requireBlacksmithWorkflows() {
  const workflowFiles = listFiles('.github/workflows', (relativePath) => /\.(ya?ml)$/.test(relativePath))
  for (const workflowFile of workflowFiles) {
    const source = readText(workflowFile)
    if (/\b(?:ubuntu|macos|windows)-latest\b/.test(source)) {
      failures.push(`${workflowFile} uses a GitHub-hosted latest runner label`)
    }
    for (const match of source.matchAll(/^\s*runs-on:\s*['"]?([^'"\n#]+)['"]?/gm)) {
      const runner = match[1].trim()
      if (!runner.includes('blacksmith-')) {
        failures.push(`${workflowFile} has non-Blacksmith runner: ${runner}`)
      }
    }
  }

  const nativePackages = readText('.github/workflows/native-packages.yml')
  if (!/runs-on:\s*blacksmith-6vcpu-macos-15\b/.test(nativePackages)) {
    failures.push('native package workflow must stay on blacksmith-6vcpu-macos-15')
  }
}

function expectedWorkflowNodeVersion(workflowFile) {
  if (workflowFile === '.github/workflows/build-admin-on-pr.yml') {
    return {
      version: '24',
      description: 'admin legacy WebUI CI must use Node 24 until @openzim/libzim supports current Node majors',
    }
  }

  return {
    version: '26',
    description: 'native release CI must use Node 26',
  }
}

function requireWorkflowNodeVersions() {
  const workflowFiles = listFiles('.github/workflows', (relativePath) => /\.(ya?ml)$/.test(relativePath))
  for (const workflowFile of workflowFiles) {
    const source = readText(workflowFile)
    if (!/actions\/setup-node@/i.test(source)) {
      continue
    }

    const expected = expectedWorkflowNodeVersion(workflowFile)
    const usesNodeVersionFile = /^\s*node-version-file:\s*['"]?\.nvmrc['"]?\s*$/m.test(source)
    const nodeVersionMatches = [...source.matchAll(/^\s*node-version:\s*['"]?([^'"\n#]+)['"]?/gm)]
    if (usesNodeVersionFile && expected.version === '26') {
      continue
    }
    if (usesNodeVersionFile && expected.version !== '26') {
      failures.push(`${workflowFile} uses .nvmrc, but ${expected.description}`)
      continue
    }
    if (nodeVersionMatches.length === 0) {
      failures.push(`${workflowFile} uses setup-node without node-version ${expected.version}`)
      continue
    }

    for (const match of nodeVersionMatches) {
      const nodeVersion = match[1].trim()
      if (nodeVersion !== expected.version) {
        failures.push(`${workflowFile} pins setup-node to Node ${nodeVersion}; ${expected.description}`)
      }
    }
  }
}

function requireNoMachineSpecificReleaseText() {
  const releaseTextFiles = [
    ...listFiles('docs/release-gates', (relativePath) => /\.(?:json|md|txt)$/.test(relativePath)),
    ...listFiles('scripts/tests', (relativePath) => /\.(?:mjs|js|cjs)$/.test(relativePath)),
  ]
  for (const relativePath of releaseTextFiles) {
    const source = readText(relativePath)
    if (/\/Users\/roach|\/Volumes\/(?:Parodox|Black)\b/.test(source)) {
      failures.push(`${relativePath} includes a machine-specific local path`)
    }
  }
}

const forbiddenBundleNames = new Set(['node_modules', 'RoachNetSource', 'RoachNetSource.tar.gz'])
const forbiddenBundleExtensions = new Set(['.js', '.mjs', '.cjs', '.node'])
const forbiddenBundleDataPatterns = [/\.zim$/i, /\.sqlite(?:$|[-.])/i, /\.db(?:$|[-.])/i, /\.jsonl$/i, /\.ndjson$/i]

function requireNoNodeOrJavaScriptInBuiltApps() {
  const requireFreshDist = process.env.ROACHNET_REQUIRE_FRESH_DIST === '1'
  for (const bundle of ['RoachNet.app', 'RoachNet Setup.app']) {
    const bundlePath = path.join(repoRoot, 'native', 'macos', 'dist', bundle)
    if (!fs.existsSync(path.join(bundlePath, 'Contents'))) continue
    if (!fs.existsSync(path.join(bundlePath, 'Contents', 'Helpers', 'roachnet-runtime'))) {
      // Bundle predates the native Swift runtime packaging lane. It is a stale local
      // artifact (dist/ is git-ignored), not a source defect, unless this is the
      // release gate that inspects freshly packaged output.
      const message = `${bundle} in native/macos/dist predates the native runtime (no Contents/Helpers/roachnet-runtime); rebuild with npm run native:dist`
      if (requireFreshDist) failures.push(message)
      else staleNotices.push(message)
      continue
    }
    const walk = (folder) => {
      for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
        const entryPath = path.join(folder, entry.name)
        const shown = `${bundle}/${path.relative(bundlePath, entryPath).split(path.sep).join('/')}`
        if (forbiddenBundleNames.has(entry.name) || forbiddenBundleExtensions.has(path.extname(entry.name).toLowerCase())
            || (entry.name === 'node' && !entry.isDirectory())) {
          failures.push(`${shown} is Node, JavaScript or RoachNet source; native builds ship none`)
        } else if (forbiddenBundleDataPatterns.some((pattern) => pattern.test(entry.name))) {
          failures.push(`${shown} is local data that must not ship`)
        } else if (entry.isDirectory() && !entry.isSymbolicLink()) {
          walk(entryPath)
        }
      }
    }
    walk(bundlePath)
  }
}

function requireRoachSpeechNativeReleaseScope() {
  const forbiddenPaths = [
    'native/macos/Sources/RoachSpeechWhisperEngine',
    'native/macos/Vendor/RoachSpeech/whisper/bin/whisper-cli',
    'native/macos/Vendor/RoachSpeech/piper/bin/piper',
  ]

  for (const relativePath of forbiddenPaths) {
    if (fs.existsSync(path.join(repoRoot, relativePath))) {
      failures.push(`RoachSpeech native lane has forbidden sidecar payload: ${relativePath}`)
    }
  }

  const packageSource = readText('native/macos/Package.swift')
  for (const pattern of [/RoachSpeechWhisperEngine/, /cxxLanguageStandard/, /whisper-cli/, /PythonKit/, /python3?\b/i]) {
    if (pattern.test(packageSource)) {
      failures.push(`Package.swift still contains forbidden RoachSpeech native pattern: ${pattern}`)
    }
  }

  const speechSource = readText('native/macos/Sources/RoachNetApp/RoachSpeechController.swift')
  for (const pattern of [
    /import\s+RoachSpeechWhisperEngine/,
    /import\s+PythonKit/,
    /roachspeech_whisper_/,
    /ROACHNET_WHISPER_CPP_BIN/,
    /ROACHNET_PIPER_BIN/,
    /python3?\b/i,
    /coremltools/i,
    /Process\(\)/,
    /AVAudioPlayer/,
    /AVAudioConverter/,
  ]) {
    if (pattern.test(speechSource)) {
      failures.push(`RoachSpeechController still contains forbidden sidecar/runtime pattern: ${pattern}`)
    }
  }

  const speechNativeSource = readText('native/macos/Sources/RoachNetApp/RoachWhisperNativeEngine.swift')
  for (const pattern of [/PythonKit/, /python3?\b/i, /coremltools/i, /Process\(\)/, /whisper-cli/, /piper\b/]) {
    if (pattern.test(speechNativeSource)) {
      failures.push(`RoachWhisperNativeEngine still contains forbidden non-Swift runtime pattern: ${pattern}`)
    }
  }

  for (const relativePath of [
    'scripts/import-roachspeech-coreml-from-whispercpp.mjs',
    'scripts/import-roachwhisper-coreml-from-whisperkit.mjs',
    'scripts/import-roachvoice-chatterbox-coreml.mjs',
    'scripts/import-roachvoice-kokoro-coreml.mjs',
    'scripts/create-roachspeech-native-pack.mjs',
  ]) {
    if (!fs.existsSync(path.join(repoRoot, relativePath))) continue
    const source = readText(relativePath)
    for (const pattern of [/\bpython3?\b/i, /coremltools/i, /\.py\b/i]) {
      if (pattern.test(source)) {
        failures.push(`${relativePath} must stay Node/Swift tooling and not shell out to Python/CoreMLTools: ${pattern}`)
      }
    }
  }

  const roachSpeechVendorPath = path.join(repoRoot, 'native/macos/Vendor/RoachSpeech')
  if (fs.existsSync(roachSpeechVendorPath)) {
    for (const relativePath of listFiles('native/macos/Vendor/RoachSpeech')) {
      const basename = path.basename(relativePath)
      const extension = path.extname(relativePath)
      if (['.dylib', '.so', '.a', '.dll'].includes(extension) || basename === 'whisper-cli' || basename === 'piper') {
        failures.push(`RoachSpeech bundles a forbidden speech binary: ${relativePath}`)
      }
      if (['.onnx', '.pt', '.pth', '.safetensors', '.gguf'].includes(extension)) {
        failures.push(`RoachSpeech final bundle must contain RoachNet-native Core ML assets, not upstream model/runtime blobs: ${relativePath}`)
      }
    }
  }

  requireCompleteRoachSpeechModelPacks()
}

function hasNonEmptyFile(absolutePath) {
  if (!fs.existsSync(absolutePath)) {
    return false
  }
  const stat = fs.statSync(absolutePath)
  if (stat.isFile()) {
    return stat.size > 0
  }
  if (!stat.isDirectory()) {
    return false
  }
  for (const entry of fs.readdirSync(absolutePath, { withFileTypes: true })) {
    if (hasNonEmptyFile(path.join(absolutePath, entry.name))) {
      return true
    }
  }
  return false
}

function requireNonEmptyFile(relativePath, label) {
  const absolutePath = path.join(repoRoot, relativePath)
  if (!fs.existsSync(absolutePath) || !fs.statSync(absolutePath).isFile() || fs.statSync(absolutePath).size === 0) {
    failures.push(`${label} must be a non-empty file: ${relativePath}`)
  }
}

function requireNonEmptyCompiledModelBundle(relativePath, label) {
  const absolutePath = path.join(repoRoot, relativePath)
  if (!fs.existsSync(absolutePath) || !fs.statSync(absolutePath).isDirectory() || !hasNonEmptyFile(absolutePath)) {
    failures.push(`${label} must be a non-empty .mlmodelc bundle: ${relativePath}`)
  }
}

function requireManifestFields(manifest, expectedKind, expectedFeatures, label) {
  if (manifest.kind !== expectedKind) {
    failures.push(`${label} manifest kind must be ${expectedKind}`)
  }
  if (manifest.nativeFormat !== 'coreML') {
    failures.push(`${label} manifest nativeFormat must be coreML`)
  }
  if (manifest.noNetwork !== true || manifest.noPackagedBinary !== true) {
    failures.push(`${label} manifest must guarantee noNetwork and noPackagedBinary`)
  }
  if (manifest.nativeInferenceReady !== true) {
    failures.push(`${label} manifest must set nativeInferenceReady true for v${rootPackage.version}`)
  }
  if (expectedKind === 'roachWhisper' && manifest.parityValidated !== true) {
    failures.push(`${label} manifest must set parityValidated true before RoachWhisper ships`)
  }
  const features = new Set(manifest.features || [])
  for (const feature of expectedFeatures) {
    if (!features.has(feature)) {
      failures.push(`${label} manifest must include feature ${feature}`)
    }
  }
}

function loadModelPackManifests() {
  const modelPacksRoot = path.join(repoRoot, 'native/macos/Vendor/RoachSpeech/ModelPacks')
  const mustValidateGeneratedPacks = process.platform === 'darwin' || process.env.ROACHNET_REQUIRE_GENERATED_ROACHSPEECH_PACKS === '1'
  if (!mustValidateGeneratedPacks) {
    console.log('RoachSpeech generated model packs are not audited on this non-macOS source host; Gate C must hydrate and validate them on Apple Silicon.')
    return null
  }
  if (!fs.existsSync(modelPacksRoot)) {
    failures.push(`RoachSpeech v${rootPackage.version} requires generated native model packs under native/macos/Vendor/RoachSpeech/ModelPacks`)
    return []
  }
  return fs.readdirSync(modelPacksRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .flatMap((entry) => {
      const relativeRoot = `native/macos/Vendor/RoachSpeech/ModelPacks/${entry.name}`
      const manifestPath = path.join(repoRoot, relativeRoot, 'RoachSpeechPack.json')
      if (!fs.existsSync(manifestPath)) {
        failures.push(`RoachSpeech model pack is missing manifest: ${relativeRoot}/RoachSpeechPack.json`)
        return []
      }
      try {
        return [{ relativeRoot, manifest: JSON.parse(fs.readFileSync(manifestPath, 'utf8')) }]
      } catch (error) {
        failures.push(`RoachSpeech model pack manifest is invalid JSON: ${relativeRoot}/RoachSpeechPack.json`)
        return []
      }
    })
}

function requireCompleteRoachWhisperPack(pack) {
  const label = `RoachWhisper pack ${pack.relativeRoot}`
  requireManifestFields(pack.manifest, 'roachWhisper', ['speechToText', 'transcriptSidecars', 'lyricExtraction'], label)
  if (pack.manifest.provenance?.upstreamProject !== 'RoachWares/RoachNet') {
    failures.push(`${label} manifest must identify RoachWares/RoachNet as the native model-pack owner`)
  }
  if (!String(pack.manifest.provenance?.referenceProject || '').includes('whisper.cpp')) {
    failures.push(`${label} manifest must keep whisper.cpp as a reference/provenance note without shipping the upstream runtime`)
  }
  requireNonEmptyCompiledModelBundle(`${pack.relativeRoot}/RoachWhisper/RoachWhisperEncoder.mlmodelc`, `${label} encoder`)
  requireNonEmptyCompiledModelBundle(`${pack.relativeRoot}/RoachWhisper/RoachWhisperDecoder.mlmodelc`, `${label} decoder`)
  requireNonEmptyFile(`${pack.relativeRoot}/RoachWhisper/RoachWhisperTokenizer.json`, `${label} tokenizer`)
  requireNonEmptyFile(`${pack.relativeRoot}/RoachWhisper/RoachWhisperParity.json`, `${label} parity manifest`)
  requireRoachWhisperParityManifest(pack, label)
}

function requireRoachWhisperParityManifest(pack, label) {
  const parityPath = `${pack.relativeRoot}/RoachWhisper/RoachWhisperParity.json`
  const absolutePath = path.join(repoRoot, parityPath)
  if (!fs.existsSync(absolutePath)) {
    return
  }

  let parity
  try {
    parity = JSON.parse(fs.readFileSync(absolutePath, 'utf8'))
  } catch (error) {
    failures.push(`${label} parity manifest must be valid JSON`)
    return
  }

  if (parity.validated !== true || parity.status !== 'release-ready') {
    failures.push(`${label} parity manifest must be validated and release-ready`)
  }
  if (!String(parity.runtime || '').includes('Swift/Core ML')) {
    failures.push(`${label} parity manifest must identify the native Swift/Core ML runtime`)
  }
  if (!String(parity.referenceRuntime || '').includes('whisper.cpp')) {
    failures.push(`${label} parity manifest must keep the whisper.cpp reference runtime visible`)
  }

  const fixtures = Array.isArray(parity.fixtures) ? parity.fixtures : []
  const hasSilenceFixture = fixtures.some((fixture) =>
    fixture?.name === 'zero-silence-1s'
      && fixture.expected === ''
      && String(fixture.nativeCheck || '').includes('testLocalStagedCoreMLPackRunsSmokeAndGreedyDecodeWhenPresent')
  )
  const hasTranscriptFixture = fixtures.some((fixture) =>
    fixture?.name === 'jfk-whispercpp-sample'
      && typeof fixture.sha256 === 'string'
      && fixture.sha256.length === 64
      && String(fixture.referenceTranscript || '').includes('ask not what your country')
      && Array.isArray(fixture.nativeRequiredPhrases)
      && fixture.nativeRequiredPhrases.length >= 2
      && String(fixture.nativeCheck || '').includes('testLocalJFKFixtureDecodesExpectedTextWhenProvided')
  )
  if (!hasSilenceFixture) {
    failures.push(`${label} parity manifest must include the zero-silence hallucination guard`)
  }
  if (!hasTranscriptFixture) {
    failures.push(`${label} parity manifest must include a reference transcript fixture`)
  }
}

function requireCompleteRoachVoicePack(pack) {
  const label = `RoachVoice pack ${pack.relativeRoot}`
  requireManifestFields(pack.manifest, 'roachVoice', ['customVoiceSynthesis', 'voiceCloning'], label)
  if (pack.manifest.provenance?.upstreamProject !== 'RoachWares/RoachNet') {
    failures.push(`${label} manifest must identify RoachWares/RoachNet as the native model-pack owner`)
  }
  if (!String(pack.manifest.provenance?.referenceProject || '').includes('chatterbox-turbo')) {
    failures.push(`${label} manifest must keep Chatterbox-Turbo as a reference/provenance note for the RoachVoice cloning model`)
  }
  const splitAcoustic = path.join(repoRoot, pack.relativeRoot, 'RoachVoice', 'RoachVoiceAcoustic.mlmodelc')
  const splitVocoder = path.join(repoRoot, pack.relativeRoot, 'RoachVoice', 'RoachVoiceVocoder.mlmodelc')
  const combinedNarrator = path.join(repoRoot, pack.relativeRoot, 'RoachVoice', 'RoachVoiceNarrator.mlmodelc')
  const languageModel = path.join(repoRoot, pack.relativeRoot, 'RoachVoice', 'RoachVoiceLanguageModel.mlmodelc')
  const conditionalDecoder = path.join(repoRoot, pack.relativeRoot, 'RoachVoice', 'RoachVoiceConditionalDecoder.mlmodelc')
  const speechEncoder = path.join(repoRoot, pack.relativeRoot, 'RoachVoice', 'RoachVoiceSpeechEncoder.mlmodelc')
  const embedTokens = path.join(repoRoot, pack.relativeRoot, 'RoachVoice', 'RoachVoiceEmbedTokens.mlmodelc')
  const tokenizer = path.join(repoRoot, pack.relativeRoot, 'RoachVoice', 'RoachVoiceTokenizer.json')
  const hasSplitModels = hasNonEmptyFile(splitAcoustic) && hasNonEmptyFile(splitVocoder)
  const hasCombinedNarrator = hasNonEmptyFile(combinedNarrator)
  const hasChatterboxTurboStack = [
    languageModel,
    conditionalDecoder,
    speechEncoder,
    embedTokens,
    tokenizer,
  ].every(hasNonEmptyFile)
  if (!hasChatterboxTurboStack) {
    failures.push(`${label} must include the RoachNet-native Chatterbox-Turbo Core ML stack for final voice cloning`)
  }
  if (!hasSplitModels && !hasCombinedNarrator && !hasChatterboxTurboStack) {
    failures.push(`${label} must include split, narrator, or Chatterbox-Turbo .mlmodelc bundles`)
  }
  requireNonEmptyFile(`${pack.relativeRoot}/RoachVoice/RoachVoiceEmbedding.json`, `${label} voice embedding`)
}

function requireCompleteRoachSpeechModelPacks() {
  const packs = loadModelPackManifests()
  if (packs === null) return
  const whisperPack = packs.find((pack) => pack.manifest.kind === 'roachWhisper')
  const voicePack = packs.find((pack) => pack.manifest.kind === 'roachVoice')
  if (!whisperPack) {
    failures.push(`RoachSpeech v${rootPackage.version} requires a complete native RoachWhisper Core ML model pack`)
  } else {
    requireCompleteRoachWhisperPack(whisperPack)
  }
  if (!voicePack) {
    failures.push(`RoachSpeech v${rootPackage.version} requires a complete native RoachVoice Core ML model pack`)
  } else {
    requireCompleteRoachVoicePack(voicePack)
  }
}

const rootPackage = readJson('package.json')
requirePackageLockMatchesManifest('package.json', 'package-lock.json', 'root')
requireNodeEngine(rootPackage, 'root', '>=26 <27')
if (fs.existsSync(path.join(repoRoot, 'admin'))) {
  failures.push('legacy admin/WebUI source must remain outside the public native candidate')
}
if (readText('.nvmrc').trim() !== '26') {
  failures.push('.nvmrc must keep the build and test tooling on Node 26 (RoachNet itself ships no Node)')
}
if (rootPackage.main) {
  failures.push('package.json must not name a JavaScript entry point; RoachNet runs only its Swift runtime')
}
// The JavaScript runtimes, the Electron shells and the Docker image are retired (ROA-78).
for (const relativePath of [
  'scripts/run-roachnet-native-api.mjs',
  'scripts/run-roachnet-setup.mjs',
  'scripts/run-roachnet.mjs',
  'scripts/roachnet-companion-server.mjs',
  'desktop',
  'installer',
  'setup-ui',
  'Dockerfile',
]) {
  if (fs.existsSync(path.join(repoRoot, relativePath))) {
    failures.push(`${relativePath} is a retired JavaScript, Electron or Docker lane and must stay out of the repository`)
  }
}
requireNoKeys(rootPackage.dependencies, ['electron', 'electron-builder', 'electron-log', 'electron-updater'], 'root dependencies')
requireNoKeys(rootPackage.devDependencies, ['electron', 'electron-builder', 'electron-log', 'electron-updater'], 'root devDependencies')
requireNoPackagePattern(rootPackage, /^electron(?:-|$)/, 'root package')

for (const [scriptName, command] of Object.entries(rootPackage.scripts || {})) {
  if (/electron|electron-builder|desktop:|installer:|build:web|npm\s+--prefix\s+admin|run-roachnet\.mjs/i.test(`${scriptName} ${command}`)) {
    failures.push(`package script ${scriptName} still points at the legacy Electron lane`)
  }
}

requireFile('native/macos/Sources/RoachNetApp/main.swift', 'native app entrypoint')
requireFile('native/macos/Sources/RoachNetSetup/main.swift', 'native setup app entrypoint')
requireFile('native/macos/Sources/RoachNetApp/RoachArcadeView.swift', 'RoachArcade native surface')
requireFile('native/macos/Sources/RoachNetApp/RoachArchiveView.swift', 'Vault native surface')
requireFile('native/macos/Sources/RoachNetApp/DevWorkspaceView.swift', 'Dev native surface')
requireFile('native/macos/Sources/RoachNetApp/RoachNetSettingsView.swift', 'Settings native surface')
requireFile('native/macos/Sources/RoachNetApp/RoachNetAboutView.swift', 'About native surface')
requireFile('native/macos/Sources/RoachNetCore/ManagedAppRuntime.swift', 'managed local runtime bridge')
requireFile('scripts/build-native-macos-apps.mjs', 'native packaging script')

const buildScript = fs.readFileSync(path.join(repoRoot, 'scripts', 'build-native-macos-apps.mjs'), 'utf8')
for (const requiredToken of [
  'copyNativeRuntimeHelper(binPath, contentsPath)',
  'copyNativeRuntimeData(resourcesPath)',
  'verifyNativeRuntimeHelper(desktopBundlePath',
  'verifyNativeRuntimeHelper(setupBundlePath',
  'assertNoNodeOrJavaScript(desktopBundlePath',
  'assertNoNodeOrJavaScript(setupBundlePath',
  'supportedBuildNodeMajorRange',
]) {
  if (!buildScript.includes(requiredToken)) {
    failures.push(`native packaging script is missing a native-only guard: ${requiredToken}`)
  }
}
for (const forbiddenToken of [
  'ROACHNET_BUNDLE_NODE_COMPAT',
  'ROACHNET_BUNDLE_OPENCLAW',
  'ensureBundledNodeRuntime',
  'copyBundledNodeRuntime',
  'createBundledSourceArchive',
  'copyBundledSourceTree',
  'bundled-admin-build-node-modules',
  'ensureAdminBuildRuntimeDependencies',
  'build-admin-runtime.mjs',
]) {
  if (buildScript.includes(forbiddenToken)) {
    failures.push(`native packaging script can still put Node or RoachNet source in a bundle: ${forbiddenToken}`)
  }
}

requireNativeSwiftRuntime()

requireNoThirdPartyImports(
  [
    'scripts/build-native-macos-apps.mjs',
    ...listFiles('scripts/lib', (relativePath) => /\.(?:mjs|js|cjs)$/.test(relativePath)),
  ],
  'native packaging script'
)
requireBlacksmithWorkflows()
requireWorkflowNodeVersions()
requireNoMachineSpecificReleaseText()
requireRoachSpeechNativeReleaseScope()
requireNoNodeOrJavaScriptInBuiltApps()

for (const notice of staleNotices) {
  console.warn(`notice: ${notice}`)
}

if (failures.length > 0) {
  console.error('Native release scope audit failed.')
  console.error('')
  for (const failure of failures) {
    console.error(`- ${failure}`)
  }
  console.error('')
  console.error('Fix these before shipping the native public build.')
  process.exit(1)
}

console.log('Native release scope audit passed.')
