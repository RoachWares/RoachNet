import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// Claude and ChatGPT plans as RoachNet models (ROA-52): claude:… and codex:…
// on the Ollama and OpenAI-compatible APIs, through stand-ins for the
// person's own Claude Code and Codex.
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const binary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const needsBinary = binary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

const fakeClaude = `#!${process.execPath}
const fs = require('fs')
const args = process.argv.slice(2)
if (args[0] === '--version') { console.log('9.9.9 (Claude Code)'); process.exit(0) }
if (args[0] === 'auth') { console.log(JSON.stringify({ loggedIn: true, authMethod: 'claude.ai', subscriptionType: 'pro' })); process.exit(0) }
const stdin = fs.readFileSync(0, 'utf8')
fs.appendFileSync(process.env.HOME + '/calls.log', JSON.stringify({ cli: 'claude', args, stdin }) + '\\n')
const out = (event) => process.stdout.write(JSON.stringify(event) + '\\n')
const model = args[args.indexOf('--model') + 1]
let reply = 'Private, fast, offline, yours, free.'
if (stdin.includes('JSON object')) reply = '{"action":"finish","summary":"Tagline: your hardware, your intelligence."}'
out({ type: 'system', subtype: 'init', session_id: 'p1', model: 'claude-' + model + '-test', apiKeySource: 'none' })
const half = Math.ceil(reply.length / 2)
for (const piece of [reply.slice(0, half), reply.slice(half)]) {
  out({ type: 'stream_event', event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: piece } } })
}
out({ type: 'assistant', message: { id: 'm1', model: 'claude-' + model + '-test', content: [{ type: 'text', text: reply }], usage: { input_tokens: 40, cache_read_input_tokens: 10, output_tokens: 8 } } })
out({ type: 'result', subtype: 'success', is_error: false, result: reply, session_id: 'p1', total_cost_usd: 0.002, usage: { input_tokens: 40, cache_read_input_tokens: 10, output_tokens: 8 } })
`

const fakeCodex = `#!${process.execPath}
const fs = require('fs')
const args = process.argv.slice(2)
if (args[0] === '--version') { console.log('codex-cli 9.9.9'); process.exit(0) }
if (args[0] === 'login') { console.log('Logged in using ChatGPT'); process.exit(0) }
if (args[0] === 'debug') { console.log(JSON.stringify({ models: [{ slug: 'gpt-plan', visibility: 'list' }] })); process.exit(0) }
const stdin = fs.readFileSync(0, 'utf8')
fs.appendFileSync(process.env.HOME + '/calls.log', JSON.stringify({ cli: 'codex', args, stdin }) + '\\n')
const out = (event) => process.stdout.write(JSON.stringify(event) + '\\n')
out({ type: 'thread.started', thread_id: 't1' })
out({ type: 'turn.started' })
out({ type: 'item.completed', item: { id: 'item_0', type: 'agent_message', text: 'It keeps working without a connection.' } })
out({ type: 'turn.completed', usage: { input_tokens: 300, cached_input_tokens: 200, output_tokens: 9 } })
`

async function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

async function startRuntime() {
  const root = await mkdtemp(path.join(os.tmpdir(), 'rn-plan-'))
  const bin = path.join(root, '.local', 'bin')
  mkdirSync(bin, { recursive: true })
  writeFileSync(path.join(bin, 'claude'), fakeClaude); chmodSync(path.join(bin, 'claude'), 0o755)
  writeFileSync(path.join(bin, 'codex'), fakeCodex); chmodSync(path.join(bin, 'codex'), 0o755)
  writeFileSync(path.join(root, 'calls.log'), '')
  const [port, modelPort] = [await freePort(), await freePort()]
  const child = spawn(binary, [], {
    env: {
      // The CLIs are found in ~/.local/bin, as on a real Mac, not on PATH.
      PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`,
      HOME: root,
      HOST: '127.0.0.1',
      PORT: String(port),
      ROACHNET_REPO_ROOT: repoRoot,
      ROACHNET_STORAGE_PATH: path.join(root, 'storage'),
      ROACHNET_COMPANION_ENABLED: '0',
      ROACHNET_ORG_SCHEDULER: '0',
      OLLAMA_BASE_URL: `http://127.0.0.1:${modelPort}`,
    },
    stdio: 'ignore',
  })
  const base = `http://127.0.0.1:${port}`
  const models = `http://127.0.0.1:${modelPort}`
  for (let i = 0; i < 100; i += 1) {
    try { if ((await fetch(`${base}/api/health`)).ok) break } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  await fetch(`${base}/api/roachclaw/status`).catch(() => {})
  for (let i = 0; i < 100; i += 1) {
    try { if ((await fetch(`${models}/api/version`)).ok) return { root, base, models, child } } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  child.kill('SIGTERM')
  throw new Error('runtime did not start')
}

async function call(base, method, route, body) {
  const response = await fetch(`${base}${route}`, { method, headers: { 'content-type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) })
  const text = await response.text()
  let json = null
  try { json = JSON.parse(text) } catch {}
  return { status: response.status, json, text }
}

const calls = (root) => readFileSync(path.join(root, 'calls.log'), 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line))

test('plan models stay off until the person turns them on, then answer on both APIs', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    assert.deepEqual((await call(runtime.models, 'GET', '/api/tags')).json.models, [])
    const refused = await call(runtime.models, 'POST', '/api/chat', { model: 'claude:haiku', stream: false, messages: [{ role: 'user', content: 'hi' }] })
    assert.equal(refused.status, 403)
    assert.equal(calls(runtime.root).length, 0, 'nothing reaches the CLI while plans are off')

    const turnedOn = (await call(runtime.base, 'PUT', '/api/roachclaw/subscriptions', { claude: true, codex: true })).json.subscriptions
    assert.deepEqual(turnedOn.map((item) => [item.provider, item.enabled, item.signedIn, item.plan]), [['claude', true, true, 'pro'], ['codex', true, true, 'chatgpt']])
    const tags = (await call(runtime.models, 'GET', '/api/tags')).json.models.map((model) => model.name)
    assert.deepEqual(tags, ['claude:sonnet', 'claude:opus', 'claude:haiku', 'codex:gpt-plan'])
    const openAIModels = (await call(runtime.models, 'GET', '/v1/models')).json.data
    assert.equal(openAIModels.find((model) => model.id === 'codex:gpt-plan').owned_by, 'openai (Codex)')

    const chat = await call(runtime.models, 'POST', '/api/chat', { model: 'claude:haiku', stream: false, messages: [
      { role: 'system', content: 'Five words only.' }, { role: 'user', content: 'Why local AI?' }, { role: 'assistant', content: 'Because.' }, { role: 'user', content: 'More.' }] })
    assert.equal(chat.status, 200)
    assert.equal(chat.json.message.content, 'Private, fast, offline, yours, free.')
    assert.equal(chat.json.done, true)
    assert.equal(chat.json.eval_count, 8)
    const claudeCall = calls(runtime.root).find((entry) => entry.cli === 'claude')
    assert.equal(claudeCall.args[claudeCall.args.indexOf('--model') + 1], 'haiku')
    assert.equal(claudeCall.args[claudeCall.args.indexOf('--tools') + 1], '', 'a plan model runs with no tools')
    assert.ok(claudeCall.args.includes('--no-session-persistence'))
    assert.equal(claudeCall.args[claudeCall.args.indexOf('--system-prompt') + 1], 'Five words only.')
    assert.match(claudeCall.stdin, /User: Why local AI\?[\s\S]*Assistant: Because\.[\s\S]*User: More\./)

    const streamed = await fetch(`${runtime.models}/api/chat`, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'claude:sonnet', messages: [{ role: 'user', content: 'Go.' }] }) })
    const chunks = (await streamed.text()).trim().split('\n').map((line) => JSON.parse(line))
    assert.ok(chunks.length >= 3, 'deltas arrive as separate chunks')
    assert.equal(chunks.filter((chunk) => !chunk.done).map((chunk) => chunk.message.content).join(''), 'Private, fast, offline, yours, free.')
    assert.equal(chunks.at(-1).done, true)

    const codex = await call(runtime.models, 'POST', '/v1/chat/completions', { model: 'codex:gpt-plan', messages: [{ role: 'user', content: 'One benefit of offline-first?' }] })
    assert.equal(codex.status, 200)
    assert.equal(codex.json.choices[0].message.content, 'It keeps working without a connection.')
    assert.equal(codex.json.usage.prompt_tokens, 300)
    assert.equal(codex.json.usage.prompt_tokens_details.cached_tokens, 200)
    const codexCall = calls(runtime.root).find((entry) => entry.cli === 'codex')
    assert.ok(codexCall.args.includes('--ephemeral'))
    assert.ok(codexCall.args.includes('sandbox_mode="read-only"'))
    assert.equal(codexCall.args[codexCall.args.indexOf('-m') + 1], 'gpt-plan')

    // Each call is a model trace, included in the plan.
    const traces = (await call(runtime.base, 'GET', '/api/traces?kind=model')).json.traces
    assert.equal(traces.length, 4, 'three answered calls and the refused one')
    for (const trace of traces.filter((item) => item.status === 'ok')) {
      const detail = (await call(runtime.base, 'GET', `/api/traces/${trace.id}`)).json
      const generation = detail.observations.find((item) => item.type === 'generation')
      assert.equal(generation.cost.billingType, 'subscription_included')
      assert.equal(generation.cost.totalUsd, 0)
    }

    // A RoachClaw Org agent can think with a plan model.
    const org = (method, route, body) => call(runtime.base, method, `/api/org${route}`, body)
    const cid = (await org('POST', '/companies', { name: 'Plan Co' })).json.company.id
    const agent = (await org('POST', `/companies/${cid}/agents`, { name: 'Ada', adapterConfig: { model: 'claude:haiku', maxSteps: 2 } })).json.agent
    await org('POST', `/companies/${cid}/issues`, { title: 'A tagline', assigneeAgentId: agent.id })
    let run
    for (let i = 0; i < 100 && !run; i += 1) {
      run = (await org('GET', `/companies/${cid}/runs`)).json.runs.find((item) => item.status !== 'running' && item.status !== 'queued')
      if (!run) await new Promise((resolve) => setTimeout(resolve, 150))
    }
    assert.equal(run.status, 'succeeded', run.error ?? '')
    assert.equal(run.usage.provider, 'anthropic')
    const billing = (await org('GET', `/companies/${cid}/costs?groupBy=billing`)).json.rows.map((row) => row.key)
    assert.deepEqual(billing, ['subscription_included'])

    const turnedOff = (await call(runtime.base, 'PUT', '/api/roachclaw/subscriptions', { claude: false })).json.subscriptions
    assert.equal(turnedOff.find((item) => item.provider === 'claude').enabled, false)
    assert.deepEqual((await call(runtime.models, 'GET', '/api/tags')).json.models.map((model) => model.name), ['codex:gpt-plan'])
  } finally {
    runtime.child.kill('SIGTERM')
    await rm(runtime.root, { recursive: true, force: true })
  }
})
