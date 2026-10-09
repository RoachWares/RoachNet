import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync, copyFileSync, existsSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// Checks the hand-written Metal kernels' quantized dot products on any host:
// the MSL source is compiled as C++ against a small shim (Metal's signed
// `char` semantics included) and compared with the Swift reference on
// synthetic blocks of every type plus real rows from the test models.
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const tool = process.env.ROACHNET_INFERENCE_TOOL?.trim() || ''
const compiler = spawnSync('g++', ['--version']).status === 0 ? 'g++' : spawnSync('clang++', ['--version']).status === 0 ? 'clang++' : ''
const ready = tool && compiler ? {} : { skip: 'Set ROACHNET_INFERENCE_TOOL to a built roachnet-infer and install g++ or clang++.' }

test('Metal kernel dot products match the Swift reference for every quantization type', ready, () => {
  const work = mkdtempSync(path.join(os.tmpdir(), 'rn-msl-'))
  const swift = readFileSync(path.join(repoRoot, 'native/macos/Sources/RoachInference/MetalKernels.swift'), 'utf8')
  const msl = swift.slice(swift.indexOf('#"""') + 4, swift.indexOf('"""#'))
  const hostable = msl
    .replace('#include <metal_stdlib>', '#include "metal_shim.h"')
    .replace(/^kernel /gm, 'static ')
    .replace(/^MATVEC\(.*$/gm, '')
  writeFileSync(path.join(work, 'kernels.cpp'), hostable)
  for (const name of ['metal_shim.h', 'harness.cpp']) {
    copyFileSync(path.join(repoRoot, 'native/macos/Tests/MetalHostCheck', name), path.join(work, name))
  }
  const build = spawnSync(compiler, ['-std=c++17', '-O1', '-fsigned-char', '-Wno-attributes', '-o', 'harness', 'harness.cpp'], { cwd: work, encoding: 'utf8' })
  assert.equal(build.status, 0, build.stderr)

  const vectors = [path.join(work, 'synthetic.bin')]
  const models = process.env.ROACHNET_TEST_MODELS?.trim() || ''
  const anyModel = ['stories15M-q4_0', 'smollm2-135m-q8_0', 'qwen2.5-0.5b-q4_k_m', 'qwen3-0.6b-q8_0']
    .map((name) => path.join(models, `${name}.gguf`)).filter((file) => models && existsSync(file))
  const seed = anyModel[0]
  if (!seed) return test.skip?.('synthetic vectors need any GGUF file; set ROACHNET_TEST_MODELS')
  const synthetic = spawnSync(tool, ['dot-vectors', seed, vectors[0], '--synthetic'], { encoding: 'utf8' })
  assert.equal(synthetic.status, 0, synthetic.stderr)
  for (const [index, file] of anyModel.entries()) {
    const out = path.join(work, `model-${index}.bin`)
    assert.equal(spawnSync(tool, ['dot-vectors', file, out], { encoding: 'utf8' }).status, 0)
    vectors.push(out)
  }
  const run = spawnSync(path.join(work, 'harness'), vectors, { encoding: 'utf8' })
  assert.equal(run.status, 0, run.stdout + run.stderr)
  assert.match(run.stdout, / 0 failures/)
})
