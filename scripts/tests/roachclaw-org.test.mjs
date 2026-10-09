import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdirSync, writeFileSync, chmodSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import http from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// RoachClaw Org: native multi-agent company runtime under /api/org.
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const binary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const needsBinary = binary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }

async function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

async function startRuntime(extraEnv = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'rn-org-'))
  const storage = path.join(root, 'storage')
  mkdirSync(storage, { recursive: true })
  const port = await freePort()
  const modelPort = await freePort()
  const child = spawn(binary, [], {
    env: {
      PATH: process.env.PATH,
      HOME: root,
      HOST: '127.0.0.1',
      PORT: String(port),
      ROACHNET_REPO_ROOT: repoRoot,
      ROACHNET_STORAGE_PATH: storage,
      ROACHNET_COMPANION_ENABLED: '0',
      ROACHNET_ORG_SCHEDULER: '0',
      OLLAMA_BASE_URL: `http://127.0.0.1:${modelPort}`,
      ...extraEnv,
    },
    stdio: 'ignore',
  })
  const base = `http://127.0.0.1:${port}`
  for (let i = 0; i < 100; i += 1) {
    try {
      const response = await fetch(`${base}/api/health`)
      if (response.ok) return { root, storage, base, child }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  child.kill('SIGTERM')
  throw new Error('runtime did not start')
}

async function stop(runtime) {
  runtime.child.kill('SIGTERM')
  await rm(runtime.root, { recursive: true, force: true })
}

function client(base, headers = {}) {
  const call = async (method, route, body) => {
    const response = await fetch(`${base}/api/org${route}`, {
      method,
      headers: { 'content-type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await response.text()
    let json = null
    try { json = JSON.parse(text) } catch {}
    return { status: response.status, json, text }
  }
  return {
    get: (route) => call('GET', route),
    post: (route, body = {}) => call('POST', route, body),
    patch: (route, body) => call('PATCH', route, body),
    put: (route, body) => call('PUT', route, body),
    del: (route) => call('DELETE', route),
  }
}

async function waitFor(check, label, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await check()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  throw new Error(`timed out waiting for ${label}`)
}

async function listen(handler) {
  const server = http.createServer(handler)
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  return { server, url: `http://127.0.0.1:${server.address().port}` }
}

const readBody = (req) => new Promise((resolve) => {
  let data = ''
  req.on('data', (chunk) => { data += chunk })
  req.on('end', () => resolve(data ? JSON.parse(data) : {}))
})

test('org structure, issues, blockers, documents and export/import', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    const owner = client(runtime.base)
    const company = (await owner.post('/companies', { name: 'Roach Labs', description: 'Build private software.' })).json.company
    assert.equal(company.issuePrefix, 'ROAC')
    const cid = company.id

    const ceo = (await owner.post(`/companies/${cid}/agents`, { name: 'Ada', role: 'engineer' })).json.agent
    assert.equal(ceo.role, 'ceo', 'the first agent is the CEO')
    const eng = (await owner.post(`/companies/${cid}/agents`, { name: 'Grace', role: 'engineer', adapterType: 'http', adapterConfig: { url: 'https://example.invalid' } })).json.agent
    assert.equal(eng.reportsTo, ceo.id)
    const cycle = await owner.patch(`/companies/${cid}/agents/${ceo.id}`, { reportsTo: eng.id })
    assert.equal(cycle.status, 422, 'reporting cycles are rejected')
    const chart = (await owner.get(`/companies/${cid}/org-chart`)).json
    assert.equal(chart.roots[0].reports[0].name, 'Grace')

    const one = (await owner.post(`/companies/${cid}/issues`, { title: 'Design schema' })).json.issue
    const two = (await owner.post(`/companies/${cid}/issues`, { title: 'Build API', blockedByIssueIds: [one.identifier], assigneeUserId: 'user_local_owner' })).json.issue
    assert.equal(one.identifier, 'ROAC-1')
    assert.equal(two.status, 'blocked')
    assert.equal((await owner.patch(`/companies/${cid}/issues/${one.id}`, { blockedByIssueIds: [two.id] })).status, 422, 'dependency cycles are rejected')
    assert.equal((await owner.patch(`/companies/${cid}/issues/${two.id}`, { status: 'in_progress' })).status, 409, 'blocked issues cannot start')
    assert.equal((await owner.patch(`/companies/${cid}/issues/${one.id}`, { status: 'done' })).status, 200)
    const unblocked = (await owner.get(`/companies/${cid}/issues/${two.identifier}`)).json.issue
    assert.equal(unblocked.status, 'todo', 'closing the blocker unblocks the dependent')

    const doc1 = (await owner.put(`/companies/${cid}/issues/${two.id}/documents/plan`, { title: 'Plan', body: 'v1' })).json.document
    const doc2 = (await owner.put(`/companies/${cid}/issues/${two.id}/documents/plan`, { body: 'v2', baseRevisionId: doc1.revisionId })).json.document
    assert.equal(doc2.revisionNumber, 2)
    assert.equal((await owner.put(`/companies/${cid}/issues/${two.id}/documents/plan`, { body: 'stale', baseRevisionId: doc1.revisionId })).status, 409)
    const rev1 = (await owner.get(`/companies/${cid}/issues/${two.id}/documents/plan?revision=1`)).json.revision
    assert.equal(rev1.body, 'v1')

    const revisions = (await owner.get(`/companies/${cid}/agents/${eng.id}/revisions`)).json.revisions
    await owner.patch(`/companies/${cid}/agents/${eng.id}`, { instructions: 'Ship small PRs.' })
    const latest = (await owner.get(`/companies/${cid}/agents/${eng.id}/revisions`)).json.revisions[0]
    assert.ok(latest.changedKeys.includes('instructions'))
    await owner.post(`/companies/${cid}/agents/${eng.id}/revisions/${latest.id}/rollback`)
    assert.equal((await owner.get(`/companies/${cid}/agents/${eng.id}`)).json.agent.instructions ?? null, null, "rollback restores the earlier config")
    assert.ok(revisions.length >= 1)

    const exported = (await owner.get(`/companies/${cid}/export`)).json
    assert.equal(exported.format, 'roachclaw-org-export')
    assert.equal(exported.company.apiKeys.length, 0)
    const imported = (await owner.post('/companies/import', { ...exported, name: 'Roach Labs Copy' })).json.company
    assert.notEqual(imported.id, cid)
    assert.equal(imported.status, 'paused')
    const copiedIssues = (await owner.get(`/companies/${imported.id}/issues`)).json.issues
    assert.equal(copiedIssues.length, 2)
    assert.ok(copiedIssues.every((issue) => issue.companyId === imported.id))

    const activity = (await owner.get(`/companies/${cid}/activity?limit=50`)).json.activity
    assert.ok(activity.some((entry) => entry.action === 'issue.created'))
  } finally {
    await stop(runtime)
  }
})

test('http agents run with scoped run tokens, report costs and hit budget stops', needsBinary, async () => {
  const runtime = await startRuntime()
  const seen = []
  const agentService = await listen(async (req, res) => {
    const payload = await readBody(req)
    seen.push(payload)
    const api = client(payload.api.baseUrl, { 'x-roachnet-org-key': payload.api.runToken })
    const me = (await api.get('/me')).json
    await api.post(`/companies/${payload.company.id}/issues/${payload.issue.id}/comments`, { body: `on it (${me.kind})` })
    const forbidden = await api.patch(`/companies/${payload.company.id}/agents/${payload.agent.id}`, { adapterType: 'process' })
    await api.patch(`/companies/${payload.company.id}/issues/${payload.issue.id}`, { status: 'done', comment: `adapter edit status ${forbidden.status}` })
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ summary: 'did the work', usage: { inputTokens: 1200, outputTokens: 300, provider: 'test', model: 'mock-1' }, costCents: 150 }))
  })
  try {
    const owner = client(runtime.base)
    const cid = (await owner.post('/companies', { name: 'Budgeted' })).json.company.id
    const agent = (await owner.post(`/companies/${cid}/agents`, { name: 'Worker', adapterType: 'http', adapterConfig: { url: agentService.url }, budgetMonthlyCents: 100 })).json.agent
    const issue = (await owner.post(`/companies/${cid}/issues`, { title: 'Do a thing', assigneeAgentId: agent.id })).json.issue

    const run = await waitFor(async () => {
      const runs = (await owner.get(`/companies/${cid}/runs`)).json.runs
      return runs.find((r) => r.status !== 'running') ?? null
    }, 'http run')
    assert.equal(run.status, 'succeeded', JSON.stringify(run))
    assert.equal(run.costCents, 150)
    assert.equal(seen[0].issue.identifier, issue.identifier)

    const detail = (await owner.get(`/companies/${cid}/issues/${issue.id}`)).json
    assert.equal(detail.issue.status, 'done')
    assert.ok(detail.comments.some((c) => c.body === 'on it (agent)' && c.authorType === 'agent'))
    assert.ok(detail.comments.some((c) => c.body === 'adapter edit status 403'), 'agents cannot change adapters')

    const stale = await client(runtime.base, { 'x-roachnet-org-key': seen[0].api.runToken }).get('/me')
    assert.equal(stale.status, 401, 'run tokens expire with the run')
    const forged = await client(runtime.base, { 'x-roachnet-org-key': `rnrun_${run.id}.deadbeef` }).get('/me')
    assert.equal(forged.status, 401)

    const budgets = (await owner.get(`/companies/${cid}/budgets`)).json
    assert.ok(budgets.incidents.some((i) => i.thresholdType === 'hard'))
    const paused = (await owner.get(`/companies/${cid}/agents/${agent.id}`)).json.agent
    assert.equal(paused.status, 'paused')
    assert.equal(paused.pauseReason, 'budget')

    const second = (await owner.post(`/companies/${cid}/issues`, { title: 'More work', assigneeAgentId: agent.id })).json.issue
    const wakes = (await owner.get(`/companies/${cid}/wake-requests`)).json.wakeRequests
    assert.equal(wakes.find((w) => w.issueId === second.id).payload.skipReason, 'agent_budget_paused')

    const approval = (await owner.get(`/companies/${cid}/approvals?status=pending`)).json.approvals.find((a) => a.type === 'budget_override_required')
    assert.ok(approval)
    await owner.post(`/companies/${cid}/approvals/${approval.id}/approve`, { note: 'ok for this month' })
    assert.equal((await owner.get(`/companies/${cid}/agents/${agent.id}`)).json.agent.status, 'idle')

    const costs = (await owner.get(`/companies/${cid}/costs?groupBy=model`)).json
    assert.equal(costs.totalCents, 150)
    assert.equal(costs.rows[0].key, 'test/mock-1')
  } finally {
    agentService.server.close()
    await stop(runtime)
  }
})

test('roachclaw_local agents drive issues through the native chat API', needsBinary, async () => {
  const runtime = await startRuntime()
  const replies = [
    '{"action":"comment","body":"Starting on this."}',
    'Here you go:\n```json\n{"action":"create_issue","title":"Write tests","assignee":"self-tester"}\n```',
    '{"action":"set_status","status":"done","comment":"Shipped."}',
    '{"action":"finish","summary":"Commented, delegated and closed the issue.","comment":false}',
  ]
  const requests = []
  const model = await listen(async (req, res) => {
    const body = await readBody(req)
    requests.push(body)
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ message: { role: 'assistant', content: replies[requests.length - 1] ?? '{"action":"finish"}' }, prompt_eval_count: 50, eval_count: 10, done: true }))
  })
  try {
    const owner = client(runtime.base)
    const cid = (await owner.post('/companies', { name: 'Local AI Co', description: 'Offline-first agents.' })).json.company.id
    const lead = (await owner.post(`/companies/${cid}/agents`, { name: 'Lead', adapterConfig: { baseUrl: model.url, model: 'qwen3:0.6b' }, instructions: 'Be brief.' })).json.agent
    await owner.post(`/companies/${cid}/agents`, { name: 'Self Tester', role: 'qa', adapterType: 'http', adapterConfig: { url: 'https://example.invalid' }, heartbeat: { wakeOnDemand: false } })
    const issue = (await owner.post(`/companies/${cid}/issues`, { title: 'Add login', assigneeAgentId: lead.id, priority: 'high' })).json.issue

    const run = await waitFor(async () => (await owner.get(`/companies/${cid}/runs`)).json.runs.find((r) => r.status !== 'running') ?? null, 'local run')
    assert.equal(run.status, 'succeeded', JSON.stringify(run))
    assert.equal(run.summary, 'Commented, delegated and closed the issue.')
    assert.equal(requests[0].model, 'qwen3:0.6b')
    assert.match(requests[0].messages[0].content, /You are Lead, the ceo of Local AI Co/)
    assert.match(requests[0].messages[1].content, /ROCA-1|LOCA-1/)

    const detail = (await owner.get(`/companies/${cid}/issues/${issue.id}`)).json
    assert.equal(detail.issue.status, 'done')
    assert.equal(detail.children.length, 1)
    assert.equal(detail.children[0].title, 'Write tests')
    assert.ok(detail.comments.some((c) => c.body === 'Starting on this.'))
    const costs = (await owner.get(`/companies/${cid}/costs?groupBy=billing`)).json
    assert.equal(costs.rows[0].key, 'local')
    assert.equal(costs.rows[0].inputTokens, 200)
    const log = (await owner.get(`/companies/${cid}/runs/${run.id}/log`)).json.log
    assert.ok(log.some((entry) => entry.stream === 'tool'))
  } finally {
    model.server.close()
    await stop(runtime)
  }
})

test('process agents run owner-approved commands with the Org API in their environment', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    const script = path.join(runtime.root, 'agent.mjs')
    writeFileSync(script, `
      const base = process.env.ROACHNET_ORG_API_URL + '/api/org'
      const headers = { 'content-type': 'application/json', 'x-roachnet-org-key': process.env.ROACHNET_ORG_API_KEY }
      const c = process.env.ROACHNET_ORG_COMPANY_ID, t = process.env.ROACHNET_ORG_TASK_ID
      await fetch(base + '/companies/' + c + '/issues/' + t + '/comments', { method: 'POST', headers, body: JSON.stringify({ body: 'from process ' + process.env.ROACHNET_ORG_WAKE_REASON + ' ' + (process.env.AGENT_HOME ? 'home' : 'nohome') }) })
      console.log(JSON.stringify({ summary: 'process done', usage: { inputTokens: 5, outputTokens: 5 } }))
    `)
    chmodSync(script, 0o600)
    const owner = client(runtime.base)
    const cid = (await owner.post('/companies', { name: 'Proc Co' })).json.company.id
    const agent = (await owner.post(`/companies/${cid}/agents`, { name: 'Runner', adapterType: 'process', adapterConfig: { command: process.execPath, args: [script], timeoutSec: 30 } })).json.agent
    const issue = (await owner.post(`/companies/${cid}/issues`, { title: 'Run it', assigneeAgentId: agent.id })).json.issue
    const run = await waitFor(async () => (await owner.get(`/companies/${cid}/runs`)).json.runs.find((r) => r.status !== 'running') ?? null, 'process run')
    assert.equal(run.status, 'succeeded', JSON.stringify(run))
    assert.equal(run.exitCode, 0)
    assert.equal(run.summary, 'process done')
    const comments = (await owner.get(`/companies/${cid}/issues/${issue.id}/comments`)).json.comments
    assert.ok(comments.some((c) => c.body === 'from process assigned home'), JSON.stringify(comments))

    // A non-owner admin cannot configure host commands.
    const user = (await owner.post('/users', { name: 'Admin Pat', roachTailPeerIds: ['peer-mac-pat'] })).json.user
    await owner.post(`/companies/${cid}/members`, { userId: user.id, role: 'admin' })
    const pat = client(runtime.base, { 'x-roachtail-auth-kind': 'peer', 'x-roachtail-peer-id': 'peer-mac-pat' })
    assert.equal((await pat.get(`/companies/${cid}/agents/${agent.id}`)).json.agent.adapterConfig.command, process.execPath, 'board members see adapter config')
    const hijack = await pat.patch(`/companies/${cid}/agents/${agent.id}`, { adapterConfig: { command: '/bin/sh', args: ['-c', 'id'] } })
    assert.equal(hijack.status, 403, 'only the owner can configure host commands')
    const minted = (await pat.post(`/companies/${cid}/keys`, { name: 'pat laptop' })).json
    assert.match(minted.key, /^rnorg_/)
    const patKey = client(runtime.base, { 'x-roachnet-org-key': minted.key })
    assert.equal((await patKey.get('/me')).json.userId, user.id)
    assert.equal((await patKey.post(`/companies/${cid}/agents`, { name: 'Shell', adapterType: 'process', adapterConfig: { command: '/bin/sh' } })).status, 403)
  } finally {
    await stop(runtime)
  }
})

test('people join over RoachTail with invites; roles gate writes', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    const owner = client(runtime.base)
    const cid = (await owner.post('/companies', { name: 'Team Co' })).json.company.id
    const peer = client(runtime.base, { 'x-roachtail-auth-kind': 'peer', 'x-roachtail-peer-id': 'peer-ipad-1' })
    assert.equal((await peer.get(`/companies/${cid}`)).status, 403, 'unlinked peers see nothing')

    const viewerInvite = (await owner.post(`/companies/${cid}/invites`, { role: 'viewer' })).json
    const join = (await peer.post('/invites/accept', { token: viewerInvite.token, userName: 'Sam' })).json.joinRequest
    assert.equal(join.status, 'pending_approval')
    assert.equal((await peer.post('/invites/accept', { token: viewerInvite.token, userName: 'Sam' })).status, 409, 'invites are single use')
    await owner.post(`/companies/${cid}/join-requests/${join.id}/approve`)

    assert.equal((await peer.get(`/companies/${cid}/dashboard`)).status, 200)
    assert.equal((await peer.post(`/companies/${cid}/issues`, { title: 'nope' })).status, 403, 'viewers cannot write')

    const members = (await owner.get(`/companies/${cid}/members`)).json.members
    const sam = members.find((m) => m.user?.name === 'Sam')
    await owner.patch(`/companies/${cid}/members/${sam.id}`, { role: 'operator' })
    assert.equal((await peer.post(`/companies/${cid}/issues`, { title: 'now ok' })).status, 201)
    assert.equal((await peer.post(`/companies/${cid}/agents`, { name: 'X' })).status, 403, 'operators cannot hire without agents:create')
    assert.equal((await peer.post(`/companies/${cid}/budgets`, { amountCents: 5 })).status, 403)

    // Agent join: invite -> request -> approve -> claim an API key once.
    const agentInvite = (await owner.post(`/companies/${cid}/invites`, { allowedJoinTypes: 'agent' })).json
    const agentJoin = (await owner.post('/invites/accept', { token: agentInvite.token, requestType: 'agent', agentName: 'Remote Bot' })).json
    assert.ok(agentJoin.claimSecret)
    assert.equal((await owner.post(`/join-requests/${agentJoin.joinRequest.id}/claim`, { claimSecret: agentJoin.claimSecret })).status, 409, 'claim needs approval first')
    await owner.post(`/companies/${cid}/join-requests/${agentJoin.joinRequest.id}/approve`)
    const claimed = (await owner.post(`/join-requests/${agentJoin.joinRequest.id}/claim`, { claimSecret: agentJoin.claimSecret })).json
    assert.match(claimed.key, /^rnorg_/)
    const bot = client(runtime.base, { 'x-roachnet-org-key': claimed.key })
    assert.equal((await bot.get('/me')).json.kind, 'agent')
    assert.equal((await bot.get(`/companies/${cid}/secrets`)).status, 403)
    assert.equal((await owner.post(`/join-requests/${agentJoin.joinRequest.id}/claim`, { claimSecret: agentJoin.claimSecret })).status, 409, 'claims are single use')

    const pairing = client(runtime.base, { 'x-roachtail-auth-kind': 'pairing' })
    assert.equal((await pairing.get('/companies')).status, 403)
  } finally {
    await stop(runtime)
  }
})

test('routines create issues from webhooks and the API; secrets never leave the vault', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    const owner = client(runtime.base)
    const cid = (await owner.post('/companies', { name: 'Ops Co' })).json.company.id
    const saved = (await owner.post(`/companies/${cid}/routines`, {
      title: 'Triage {{source}} alert',
      concurrencyPolicy: 'coalesce_if_active',
      variables: [{ name: 'source', required: true }],
      triggers: [{ kind: 'webhook', signingMode: 'bearer' }, { kind: 'schedule', cronExpression: '0 9 * * 1-5', timezone: 'America/Chicago' }],
    })).json
    const routine = saved.routine
    assert.equal(saved.webhookSecrets.length, 1)
    const schedule = routine.triggers.find((t) => t.kind === 'schedule')
    assert.ok(schedule.nextRunAt)
    const webhook = routine.triggers.find((t) => t.kind === 'webhook')

    const hook = (auth, body) => fetch(`${runtime.base}/api/org/routine-triggers/${webhook.publicId}`, { method: 'POST', headers: { authorization: auth, 'content-type': 'application/json' }, body: JSON.stringify(body) })
    assert.equal((await hook('Bearer wrong', { variables: { source: 'x' } })).status, 401)
    const fired = await (await hook(`Bearer ${saved.webhookSecrets[0].secret}`, { variables: { source: 'pager' } })).json()
    assert.equal(fired.run.status, 'issue_created')
    const again = await (await hook(`Bearer ${saved.webhookSecrets[0].secret}`, { variables: { source: 'pager' } })).json()
    assert.equal(again.run.status, 'coalesced')
    const missing = (await owner.post(`/companies/${cid}/routines/${routine.id}/run`, {})).json
    assert.equal(missing.run.status, 'failed')
    const issues = (await owner.get(`/companies/${cid}/issues`)).json.issues
    assert.equal(issues.length, 1)
    assert.equal(issues[0].title, 'Triage pager alert')

    await owner.put(`/companies/${cid}/secrets/OPENAI_KEY`, { value: 'sk-test-123', name: 'Provider key' })
    const listed = (await owner.get(`/companies/${cid}/secrets`)).text
    assert.ok(!listed.includes('sk-test-123'))
    const exported = (await owner.get(`/companies/${cid}/export`)).text
    assert.ok(!exported.includes('sk-test-123'))

    const tick = (await owner.post('/engine/tick')).json
    assert.ok('heartbeatsQueued' in tick)
  } finally {
    await stop(runtime)
  }
})

test('review stages gate completion and the board approves agent hires', needsBinary, async () => {
  const runtime = await startRuntime()
  try {
    const owner = client(runtime.base)
    const cid = (await owner.post('/companies', { name: 'Gate Co', requireBoardApprovalForNewAgents: true })).json.company.id
    const ceo = (await owner.post(`/companies/${cid}/agents`, { name: 'Chief', adapterType: 'http', adapterConfig: { url: 'https://example.invalid' }, heartbeat: { wakeOnDemand: false } })).json.agent
    assert.equal(ceo.canCreateAgents, true)
    const key = (await owner.post(`/companies/${cid}/keys`, { name: 'ceo', agentId: ceo.id })).json.key
    const ceoApi = client(runtime.base, { 'x-roachnet-org-key': key })

    const hire = (await ceoApi.post(`/companies/${cid}/agents`, { name: 'New Hire', role: 'engineer', reason: 'Need hands' })).json
    assert.equal(hire.agent.status, 'pending_approval')
    assert.equal(hire.approval.type, 'hire_agent')
    assert.equal((await ceoApi.post(`/companies/${cid}/approvals/${hire.approval.id}/approve`)).status, 403, 'agents cannot approve their own hires')
    await owner.post(`/companies/${cid}/approvals/${hire.approval.id}/approve`)
    assert.equal((await owner.get(`/companies/${cid}/agents/${hire.agent.id}`)).json.agent.status, 'idle')

    const issue = (await owner.post(`/companies/${cid}/issues`, {
      title: 'Risky change', assigneeAgentId: ceo.id, status: 'todo',
      executionPolicy: { stages: [{ type: 'approval', participants: [{ type: 'user', id: 'user_local_owner' }] }] },
    })).json.issue
    const submitted = (await ceoApi.patch(`/companies/${cid}/issues/${issue.id}`, { status: 'in_progress' })).json.issue
    assert.equal(submitted.status, 'in_progress')
    const review = (await ceoApi.patch(`/companies/${cid}/issues/${issue.id}`, { status: 'done' })).json.issue
    assert.equal(review.status, 'in_review', 'done routes through the approval stage')
    assert.equal(review.assigneeUserId, 'user_local_owner')
    assert.equal((await ceoApi.post(`/companies/${cid}/issues/${issue.id}/review`, { decision: 'approve' })).status, 403)
    const inbox = (await owner.get(`/companies/${cid}/inbox`)).json
    assert.equal(inbox.reviews[0].id, issue.id)
    const changes = (await owner.post(`/companies/${cid}/issues/${issue.id}/review`, { decision: 'request_changes', comment: 'Add a rollback plan.' })).json.issue
    assert.equal(changes.status, 'in_progress')
    assert.equal(changes.assigneeAgentId, ceo.id)
    await ceoApi.patch(`/companies/${cid}/issues/${issue.id}`, { status: 'done' })
    const approved = (await owner.post(`/companies/${cid}/issues/${issue.id}/review`, { decision: 'approve' })).json.issue
    assert.equal(approved.status, 'done')
    assert.equal(approved.executionState.status, 'completed')

    const terminated = (await owner.post(`/companies/${cid}/agents/${ceo.id}/terminate`)).json.agent
    assert.equal(terminated.status, 'terminated')
    assert.equal((await ceoApi.get('/me')).status, 401, 'terminating an agent revokes its keys')
  } finally {
    await stop(runtime)
  }
})
