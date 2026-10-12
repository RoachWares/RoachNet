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

// Bring-your-own agents (ROA-51): Claude Code and Codex agents in one company,
// talking through the Org API the way Paperclip agents do. Stand-in CLIs speak
// each tool's real stream format and call the API with the roachnet-org helper.
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const binary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const needsBinary = binary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }
const nodeDir = path.dirname(process.execPath)

const shared = String.raw`
const fs = require('fs')
const { execFileSync } = require('child_process')
const args = process.argv.slice(2)
const out = (event) => process.stdout.write(JSON.stringify(event) + '\n')
const org = (...a) => JSON.parse(execFileSync('roachnet-org', a, { encoding: 'utf8' }) || 'null')
const record = (cli, extra = {}) => fs.appendFileSync(process.env.FAKE_LOG, JSON.stringify({ cli, args, task: process.env.ROACHNET_ORG_TASK_ID,
  wake: process.env.ROACHNET_ORG_WAKE_REASON, traceparent: process.env.TRACEPARENT, home: process.env.AGENT_HOME, ...extra }) + '\n')
`

const fakeClaude = `#!${process.execPath}
${shared}
if (args[0] === '--version') { console.log('9.9.9 (Claude Code)'); process.exit(0) }
if (args[0] === 'auth') { console.log(JSON.stringify({ loggedIn: true, authMethod: 'claude.ai', subscriptionType: 'max', email: 'private@example.com' })); process.exit(0) }
const stdin = fs.readFileSync(0, 'utf8')
const resumed = args.includes('--resume')
const session = resumed ? args[args.indexOf('--resume') + 1] : 'claude-session-1'
out({ type: 'system', subtype: 'init', session_id: session, model: 'claude-test', apiKeySource: 'none' })
let text = 'ok'
if (stdin.includes('Reply with the single word ok.')) {
  record('claude-probe')
} else {
  const task = process.env.ROACHNET_ORG_TASK_ID
  record('claude', { stdin: stdin.slice(0, 200), system: args[args.indexOf('--append-system-prompt') + 1].slice(0, 400) })
  out({ type: 'assistant', session_id: session, message: { id: 'msg_1', model: 'claude-test', content: [{ type: 'tool_use', id: 'tu_1', name: 'Bash', input: { command: 'roachnet-org ...' } }],
    usage: { input_tokens: 10, cache_read_input_tokens: 100, cache_creation_input_tokens: 5, output_tokens: 20 } } })
  if (process.env.ROACHNET_ORG_WAKE_REASON === 'children_completed') {
    org('PATCH', '/issues/' + task, JSON.stringify({ status: 'done', comment: 'Every sub-task is done. Closing this.' }))
    text = 'Closed it.'
  } else {
    org('POST', '/issues/' + task + '/checkout', '{}')
    const engineer = org('GET', '/agents').agents.find((agent) => agent.name === 'Linus')
    const sub = org('POST', '/issues', JSON.stringify({ title: 'Write a haiku about offline-first software', assigneeAgentId: engineer.id, parentId: task }))
    org('POST', '/issues/' + task + '/comments', JSON.stringify({ body: 'Handed ' + sub.issue.identifier + ' to Linus.' }))
    text = 'Delegated the haiku.'
  }
  out({ type: 'user', session_id: session, message: { content: [{ type: 'tool_result', tool_use_id: 'tu_1', content: 'ok' }] } })
}
out({ type: 'assistant', session_id: session, message: { id: 'msg_2', model: 'claude-test', content: [{ type: 'text', text }],
  usage: { input_tokens: 3, cache_read_input_tokens: 120, cache_creation_input_tokens: 0, output_tokens: 7 } } })
out({ type: 'rate_limit_event', rate_limit_info: { status: 'allowed', rateLimitType: 'five_hour', utilization: 0.12 } })
out({ type: 'result', subtype: 'success', is_error: false, result: text, session_id: session, total_cost_usd: 0.05, num_turns: 2,
  usage: { input_tokens: 13, cache_read_input_tokens: 220, cache_creation_input_tokens: 5, output_tokens: 27 } })
`

const fakeCodex = `#!${process.execPath}
${shared}
if (args[0] === '--version') { console.log('codex-cli 9.9.9'); process.exit(0) }
if (args[0] === 'login') { console.log('Logged in using ChatGPT'); process.exit(0) }
if (args[0] === 'debug') { console.log(JSON.stringify({ models: [{ slug: 'gpt-test', visibility: 'list' }, { slug: 'hidden', visibility: 'hide' }] })); process.exit(0) }
const stdin = fs.readFileSync(0, 'utf8')
const task = process.env.ROACHNET_ORG_TASK_ID
record('codex', { stdin: stdin.slice(0, 200) })
out({ type: 'thread.started', thread_id: 'codex-thread-1' })
out({ type: 'turn.started' })
out({ type: 'item.started', item: { id: 'item_0', type: 'command_execution', command: 'roachnet-org PATCH /issues/...', status: 'in_progress' } })
org('POST', '/issues/' + task + '/checkout', '{}')
org('PATCH', '/issues/' + task, JSON.stringify({ status: 'done' }))
out({ type: 'item.completed', item: { id: 'item_0', type: 'command_execution', command: 'roachnet-org PATCH /issues/...', aggregated_output: '{"ok":true}', exit_code: 0, status: 'completed' } })
out({ type: 'item.completed', item: { id: 'item_1', type: 'agent_message', text: 'Wires stay unplugged / your notes sleep on your own disk / the model hums home' } })
out({ type: 'turn.completed', usage: { input_tokens: 500, cached_input_tokens: 400, output_tokens: 30 } })
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
  const root = await mkdtemp(path.join(os.tmpdir(), 'rn-byo-'))
  const storage = path.join(root, 'storage')
  const bin = path.join(root, 'bin')
  mkdirSync(storage, { recursive: true })
  mkdirSync(bin, { recursive: true })
  const claude = path.join(bin, 'claude')
  const codex = path.join(bin, 'codex')
  writeFileSync(claude, fakeClaude); chmodSync(claude, 0o755)
  writeFileSync(codex, fakeCodex); chmodSync(codex, 0o755)
  const log = path.join(root, 'cli.log')
  writeFileSync(log, '')
  const port = await freePort()
  const child = spawn(binary, [], {
    env: {
      PATH: `${nodeDir}:/usr/bin:/bin`,
      HOME: root,
      HOST: '127.0.0.1',
      PORT: String(port),
      ROACHNET_REPO_ROOT: repoRoot,
      ROACHNET_STORAGE_PATH: storage,
      ROACHNET_COMPANION_ENABLED: '0',
      ROACHNET_ORG_SCHEDULER: '0',
      OLLAMA_BASE_URL: `http://127.0.0.1:${await freePort()}`,
      FAKE_LOG: log,
    },
    stdio: 'ignore',
  })
  const base = `http://127.0.0.1:${port}`
  for (let i = 0; i < 100; i += 1) {
    try {
      if ((await fetch(`${base}/api/health`)).ok) return { root, base, child, claude, codex, log }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  child.kill('SIGTERM')
  throw new Error('runtime did not start')
}

async function call(base, method, route, body) {
  const response = await fetch(`${base}${route}`, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  let json = null
  try { json = JSON.parse(text) } catch {}
  return { status: response.status, json, text }
}

async function waitFor(check, label, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await check()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 150))
  }
  throw new Error(`timed out waiting for ${label}`)
}

const readLog = (file) => readFileSync(file, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line))

test('a Claude Code CEO delegates to a Codex engineer, wakes when the work is done, and resumes its session', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    const org = (method, route, body) => call(runtime.base, method, `/api/org${route}`, body)
    const cid = (await org('POST', '/companies', { name: 'Haiku Works' })).json.company.id
    const ceo = (await org('POST', `/companies/${cid}/agents`, { name: 'Ada', adapterType: 'claude_local', adapterConfig: { command: runtime.claude, model: 'sonnet', env: { FAKE_LOG: runtime.log } } })).json.agent
    const linus = (await org('POST', `/companies/${cid}/agents`, { name: 'Linus', adapterType: 'codex_local', adapterConfig: { command: runtime.codex, model: 'gpt-test', env: { FAKE_LOG: runtime.log } } })).json.agent
    assert.equal(ceo.adapterType, 'claude_local')
    assert.equal(linus.adapterType, 'codex_local')

    const parent = (await org('POST', `/companies/${cid}/issues`, { title: 'Ship a haiku for the README', assigneeAgentId: ceo.id })).json.issue
    let done
    try {
      done = await waitFor(async () => {
        const issue = (await org('GET', `/companies/${cid}/issues/${parent.id}`)).json
        return issue.issue.status === 'done' ? issue : null
      }, 'the CEO to close the parent issue')
    } catch (error) {
      // Show what happened instead of only that it didn't.
      for (const run of (await org('GET', `/companies/${cid}/runs`)).json.runs) {
        const log = (await org('GET', `/companies/${cid}/runs/${run.id}/log`)).json
        console.error('RUN', run.agentId === ceo.id ? 'Ada' : 'Linus', run.status, run.error ?? '', JSON.stringify(run.wakeReasons ?? run.invocationSource ?? ''))
        for (const entry of log.log ?? []) console.error('  ', entry.stream, String(entry.text).slice(0, 400).replace(/\n/g, ' | '))
      }
      console.error('ISSUES', JSON.stringify((await org('GET', `/companies/${cid}/issues`)).json.issues.map((i) => [i.identifier, i.status, i.assigneeAgentId])))
      console.error('WAKES', JSON.stringify((await org('GET', `/companies/${cid}/wake-requests`)).json).slice(0, 1_500))
      throw error
    }

    const runs = await waitFor(async () => {
      const list = (await org('GET', `/companies/${cid}/runs`)).json.runs
      return list.length >= 3 && list.every((run) => run.status !== 'running' && run.status !== 'queued') ? list : null
    }, 'every run to finish')
    done = (await org('GET', `/companies/${cid}/issues/${parent.id}`)).json
    const ceoRuns = runs.filter((run) => run.agentId === ceo.id)
    const linusRuns = runs.filter((run) => run.agentId === linus.id)
    assert.equal(ceoRuns.length, 2, 'the CEO ran on assignment and again when its sub-issue finished')
    assert.equal(linusRuns.length, 1)
    for (const run of runs) assert.equal(run.status, 'succeeded', `${run.agentId} ${run.error ?? ''}`)

    // The sub-issue went to Linus with the parent linked, and he closed it.
    const children = done.children ?? []
    assert.equal(children.length, 1)
    assert.equal(children[0].status, 'done')
    assert.equal(children[0].assigneeAgentId, linus.id)

    // Linus never commented, so his final reply was posted for him; the CEO's own comments stand.
    const childDetail = (await org('GET', `/companies/${cid}/issues/${children[0].id}`)).json
    assert.ok(childDetail.comments.some((comment) => comment.authorId === linus.id && comment.body.includes('the model hums home')))
    assert.ok(done.comments.some((comment) => comment.authorId === ceo.id && comment.body.startsWith('Handed ')))
    assert.ok(done.comments.some((comment) => comment.authorId === ceo.id && comment.body.includes('Every sub-task is done')))
    assert.ok(!done.comments.some((comment) => comment.body === 'Delegated the haiku.'), 'a reply already posted as a comment is not posted twice')

    // What the CLIs were handed.
    const calls = readLog(runtime.log)
    const ceoCalls = calls.filter((entry) => entry.cli === 'claude')
    assert.equal(ceoCalls.length, 2)
    assert.deepEqual(ceoCalls.map((entry) => entry.wake), ['assigned', 'children_completed'])
    assert.ok(!ceoCalls[0].args.includes('--resume'))
    assert.equal(ceoCalls[1].args[ceoCalls[1].args.indexOf('--resume') + 1], 'claude-session-1', 'the second wake on the same issue resumes the session')
    assert.ok(ceoCalls[0].args.includes('--model') && ceoCalls[0].args.includes('sonnet'))
    assert.equal(ceoCalls[0].args[ceoCalls[0].args.indexOf('--permission-mode') + 1], 'acceptEdits')
    assert.match(ceoCalls[0].args[ceoCalls[0].args.indexOf('--allowedTools') + 1], /Bash\(roachnet-org:\*\)/)
    assert.match(ceoCalls[0].system, /You are Ada/)
    assert.match(ceoCalls[0].system, /Linus/)
    assert.match(ceoCalls[0].stdin, /Ship a haiku for the README/)
    for (const entry of calls.filter((item) => item.cli === 'claude' || item.cli === 'codex')) {
      assert.match(entry.traceparent ?? '', /^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)
    }
    const codexCall = calls.find((entry) => entry.cli === 'codex')
    assert.deepEqual(codexCall.args.slice(0, 3), ['exec', '--json', '--skip-git-repo-check'])
    assert.ok(codexCall.args.includes('sandbox_workspace_write.network_access=true'))
    assert.equal(codexCall.args.at(-1), '-')
    assert.equal(readFileSync(path.join(codexCall.home, 'ROACHNET_ORG.md'), 'utf8').startsWith('# RoachNet Org API'), true)

    // Usage and billing: both run on the person's own plan.
    const first = ceoRuns.find((run) => !run.sessionIdBefore) ?? ceoRuns[0]
    assert.equal(first.usage.inputTokens, 238)
    assert.equal(first.usage.cachedInputTokens, 220)
    assert.equal(first.usage.outputTokens, 27)
    assert.equal(first.costCents, 0)
    assert.equal(linusRuns[0].usage.inputTokens, 500)
    assert.equal(linusRuns[0].usage.cachedInputTokens, 400)
    const costs = (await org('GET', `/companies/${cid}/costs?groupBy=billing`)).json
    assert.deepEqual(costs.rows.map((row) => row.key), ['subscription_included'])
    assert.equal(costs.totalCents, 0)

    // The session is saved per issue on the agent.
    const ceoNow = (await org('GET', `/companies/${cid}/agents/${ceo.id}`)).json.agent
    assert.equal(ceoNow.sessionState.adapter, 'claude_local')
    assert.equal(ceoNow.sessionState.sessions[parent.id].id, 'claude-session-1')

    // Each run is a trace: the CLI's span, a generation per model turn, its tool calls.
    const traces = (await org('GET', `/companies/${cid}/traces`)).json.traces
    assert.equal(traces.length, 3)
    const ceoTrace = traces.find((trace) => trace.agentId === ceo.id)
    const detail = (await call(runtime.base, 'GET', `/api/traces/${ceoTrace.id}`)).json
    const names = detail.observations.map((item) => `${item.type}:${item.name}`)
    assert.ok(names.includes('span:Claude Code'))
    assert.ok(names.filter((name) => name.startsWith('generation:turn')).length >= 2)
    assert.ok(names.includes('tool:Bash') || ceoTrace.name.includes('ROAC'))
    const span = detail.observations.find((item) => item.name === 'Claude Code')
    assert.equal(span.metadata.billing, 'subscription_included')
    assert.equal(span.metadata.apiEquivalentUsd, 0.05)
    assert.equal(span.metadata.rateLimit.rateLimitType, 'five_hour')
    const generations = detail.observations.filter((item) => item.type === 'generation')
    assert.ok(generations.every((item) => item.cost.billingType === 'subscription_included' && item.cost.totalUsd === 0))
  } finally {
    runtime.child.kill('SIGTERM')
    await rm(runtime.root, { recursive: true, force: true })
  }
})

test('the owner sees which agent CLIs are installed and can test one; the account details stay out', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    const list = (await call(runtime.base, 'GET', '/api/org/adapters')).json.adapters
    assert.deepEqual(list.map((item) => item.type), ['claude_local', 'codex_local', 'gemini_local', 'opencode_local', 'cursor_local'])

    const tested = (await call(runtime.base, 'POST', '/api/org/adapters/claude_local/test', { adapterConfig: { command: runtime.claude, env: { FAKE_LOG: runtime.log } }, probe: true })).json
    assert.equal(tested.installed, true)
    assert.equal(tested.version, '9.9.9')
    assert.equal(tested.signedIn, true)
    assert.equal(tested.authMethod, 'subscription')
    assert.equal(tested.plan, 'max')
    assert.ok(!JSON.stringify(tested).includes('private@example.com'), 'the CLI account email is not passed along')
    assert.equal(tested.test.ok, true)
    assert.equal(tested.test.reply, 'ok')
    const probe = readLog(runtime.log).find((entry) => entry.cli === 'claude-probe')
    assert.ok(probe.args.includes('--no-session-persistence'))
    assert.equal(probe.args[probe.args.indexOf('--permission-mode') + 1], 'dontAsk', 'a test runs read-only')

    const codex = (await call(runtime.base, 'POST', '/api/org/adapters/codex_local/test', { adapterConfig: { command: runtime.codex } })).json
    assert.equal(codex.signedIn, true)
    assert.deepEqual(codex.models, ['gpt-test'])
    assert.equal(codex.test, undefined, 'no probe unless asked')

    const missing = (await call(runtime.base, 'POST', '/api/org/adapters/gemini_local/test', { adapterConfig: { command: '/nonexistent/gemini' }, probe: true })).json
    assert.equal(missing.installed, false)
    assert.equal((await call(runtime.base, 'POST', '/api/org/adapters/nope/test', {})).status, 404)

    // Agents can't hand themselves a CLI adapter.
    const org = (method, route, body, headers = {}) => fetch(`${runtime.base}/api/org${route}`, { method, headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) })
    const cid = (await (await org('POST', '/companies', { name: 'Keys Co' })).json()).company.id
    const agent = (await (await org('POST', `/companies/${cid}/agents`, { name: 'Bot' })).json()).agent
    const key = (await (await org('POST', `/companies/${cid}/keys`, { name: 'bot key', agentId: agent.id })).json())
    assert.match(key.key, /^rnorg_/)
    const denied = await org('PATCH', `/companies/${cid}/agents/${agent.id}`, { adapterType: 'claude_local', adapterConfig: { command: runtime.claude } }, { 'x-roachnet-org-key': key.key })
    assert.equal(denied.status, 403)
    const listed = await fetch(`${runtime.base}/api/org/adapters`, { headers: { 'x-roachnet-org-key': key.key } })
    assert.equal(listed.status, 403, 'only the owner sees what is installed on the Mac')
  } finally {
    runtime.child.kill('SIGTERM')
    await rm(runtime.root, { recursive: true, force: true })
  }
})
