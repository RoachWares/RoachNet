import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  buildRoachClawAgentPrompt,
  createRoachClawAgentRuntime,
  defaultRoachClawAgentSkills,
  loadRoachClawAgentState,
  ROACHCLAW_AGENT_REVIEWED_HERMES_HEAD,
  recordRoachClawAgentMemory,
} from '../lib/roachnet_roachclaw_agent.mjs'

test('RoachClaw native agent profile owns the agent spine without Hermes or OpenClaw runtime dependency', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachclaw-agent-profile-'))
  try {
    const runtime = createRoachClawAgentRuntime({
      storageRoot: tempRoot,
      defaultModel: 'qwen2.5-coder:7b',
    })

    const status = runtime.status({
      installedModels: ['qwen2.5-coder:7b'],
      ollamaAvailable: true,
    })

    assert.equal(status.runtime, 'roachclaw-native-agent')
    assert.equal(status.upstreamRuntimeDependency, 'none')
    assert.equal(status.references.hermesAgent.role, 'design-reference-only')
    assert.equal(status.references.hermesAgent.reviewedHead, ROACHCLAW_AGENT_REVIEWED_HERMES_HEAD)
    assert.equal(ROACHCLAW_AGENT_REVIEWED_HERMES_HEAD, '5fc308a70719a83cccdbba4c0e39c23f5a8239d5')
    assert.equal(status.references.openClaw.role, 'migration-reference-only')
    assert.equal(status.ready, true)
    assert.equal(status.defaultModel, 'qwen2.5-coder:7b')
    assert.equal(status.skills.length >= 5, true)
    assert.equal(status.policy.requiresApprovalFor.includes('shell.write'), true)
    assert.equal(status.budgets.planMaxTokens, 4096)
  } finally {
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('RoachClaw native prompt builder composes permissioned app context within an explicit budget', () => {
  const prompt = buildRoachClawAgentPrompt({
    userPrompt: 'Help with the game and the open file.',
    activeSurface: 'RoachArcade',
    context: {
      dev: 'open file: main.swift\n'.repeat(80),
      arcade: 'running game: Test Cartridge\ncontroller: Xbox Series X',
      vault: 'selected book: Local Systems',
      maps: 'offline map: Indiana',
    },
    enabledScopes: ['dev', 'arcade'],
    budgetCharacters: 900,
  })

  assert.equal(prompt.messages[0].role, 'system')
  assert.match(prompt.messages[0].content, /RoachClaw is RoachNet's native local agent/)
  assert.match(prompt.messages[1].content, /Active surface: RoachArcade/)
  assert.match(prompt.messages[1].content, /running game: Test Cartridge/)
  assert.doesNotMatch(prompt.messages[1].content, /selected book: Local Systems/)
  assert.equal(prompt.includedScopes.includes('dev'), true)
  assert.equal(prompt.includedScopes.includes('vault'), false)
  assert.equal(prompt.contextCharacters <= 900, true)
})

test('RoachClaw native agent persists local memory records into its own state folder', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'roachclaw-agent-memory-'))
  try {
    const saved = recordRoachClawAgentMemory({
      storageRoot: tempRoot,
      source: 'Dev',
      prompt: 'Fix the layout overlap.',
      response: 'Add top padding and rerun visual checks.',
      tags: ['dev', 'layout'],
    })

    const state = loadRoachClawAgentState({ storageRoot: tempRoot })
    const statePath = path.join(tempRoot, 'RoachClaw', 'agent', 'state.json')

    assert.equal(existsSync(statePath), true)
    assert.equal(state.memories.length, 1)
    assert.equal(state.memories[0].id, saved.id)
    assert.deepEqual(state.memories[0].tags, ['dev', 'layout'])
    assert.match(readFileSync(statePath, 'utf8'), /Fix the layout overlap/)
  } finally {
    await rm(tempRoot, { recursive: true, force: true })
  }
})

test('RoachClaw native skill registry covers Hermes-grade jobs with RoachNet-owned skills', () => {
  const skills = defaultRoachClawAgentSkills()
  const skillIds = new Set(skills.map((skill) => skill.id))

  for (const requiredId of [
    'app-context-router',
    'dev-agent',
    'vault-research',
    'arcade-copilot',
    'release-gate-operator',
    'memory-curator',
  ]) {
    assert.equal(skillIds.has(requiredId), true, `missing ${requiredId}`)
  }

  assert.equal(skills.every((skill) => skill.runtime === 'roachclaw-native'), true)
  assert.equal(skills.some((skill) => /hermes/i.test(skill.id + skill.title + skill.description)), false)
})
