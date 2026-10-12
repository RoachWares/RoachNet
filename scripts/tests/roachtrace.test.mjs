import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdirSync, readdirSync, statSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import http from 'node:http'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

// RoachTrace: traces of Org runs, chats and model-server calls under /api/traces.
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const binary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const needsBinary = binary ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY to a built roachnet-runtime.' }
const TRACEPARENT = /^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/

async function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

async function listen(handler) {
  const server = http.createServer(handler)
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  return { server, url: `http://127.0.0.1:${server.address().port}`, port: server.address().port }
}

const readBody = (req) => new Promise((resolve) => {
  let data = ''
  req.on('data', (chunk) => { data += chunk })
  req.on('end', () => resolve(data ? JSON.parse(data) : {}))
})

async function startRuntime(extraEnv = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'rn-trace-'))
  const storage = path.join(root, 'storage')
  mkdirSync(storage, { recursive: true })
  const port = await freePort()
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
      OLLAMA_BASE_URL: `http://127.0.0.1:${await freePort()}`,
      ...extraEnv,
    },
    stdio: 'ignore',
  })
  const base = `http://127.0.0.1:${port}`
  for (let i = 0; i < 100; i += 1) {
    try {
      if ((await fetch(`${base}/api/health`)).ok) return { root, storage, base, child }
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

async function waitFor(check, label, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const value = await check()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  throw new Error(`timed out waiting for ${label}`)
}

function attribute(span, key) {
  const entry = span.attributes.find((item) => item.key === key)
  if (!entry) return undefined
  const value = entry.value
  return value.stringValue ?? value.intValue ?? value.doubleValue ?? value.boolValue
}

test('an Org run is one trace: agent span, a generation per model call, a tool span per action', needsBinary, async () => {
  const runtime = await startRuntime()
  const replies = [
    '{"action":"comment","body":"Starting on this."}',
    '{"action":"create_issue","title":"Write tests"}',
    '{"action":"set_status","status":"done","comment":"Shipped."}',
    '{"action":"finish","summary":"Done.","comment":false}',
  ]
  const requests = []
  const model = await listen(async (req, res) => {
    const body = await readBody(req)
    requests.push({ body, traceparent: req.headers.traceparent })
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ message: { role: 'assistant', content: replies[requests.length - 1] ?? '{"action":"finish"}' }, prompt_eval_count: 50, eval_count: 10, done: true }))
  })
  try {
    const org = (method, route, body) => call(runtime.base, method, `/api/org${route}`, body)
    const cid = (await org('POST', '/companies', { name: 'Trace Co' })).json.company.id
    const lead = (await org('POST', `/companies/${cid}/agents`, { name: 'Lead', adapterConfig: { baseUrl: model.url, model: 'qwen3:0.6b' } })).json.agent
    const issue = (await org('POST', `/companies/${cid}/issues`, { title: 'Add login', assigneeAgentId: lead.id })).json.issue
    await waitFor(async () => (await org('GET', `/companies/${cid}/runs`)).json.runs.find((r) => r.status !== 'running') ?? null, 'run')

    // Every model call carried a W3C traceparent for its generation.
    assert.equal(requests.length, 4)
    for (const request of requests) assert.match(request.traceparent ?? '', TRACEPARENT)

    const list = await waitFor(async () => {
      const page = (await call(runtime.base, 'GET', '/api/traces?kind=org_run')).json
      return page.traces.find((trace) => trace.status !== 'running') ? page : null
    }, 'finished trace')
    assert.equal(list.traces.length, 1)
    const summary = list.traces[0]
    assert.equal(summary.status, 'ok')
    assert.equal(summary.agentId, lead.id)
    assert.equal(summary.issueId, issue.id)
    assert.equal(summary.sessionId, issue.id)
    assert.match(summary.name, /^Lead: TRAC-1 Add login$/)
    assert.deepEqual(summary.usage, { input: 200, output: 40, cachedInput: 0, total: 240 })
    assert.equal(summary.costUsd, 0)
    assert.equal(summary.input, undefined, 'lists leave content out unless content=1')

    const detail = (await call(runtime.base, 'GET', `/api/traces/${summary.id}`)).json
    const byType = (type) => detail.observations.filter((item) => item.type === type)
    assert.equal(byType('agent').length, 1)
    assert.equal(byType('generation').length, 4)
    assert.deepEqual(byType('tool').map((item) => item.name).sort(), ['comment', 'create_issue', 'set_status'])
    const agentId = byType('agent')[0].id
    for (const item of [...byType('generation'), ...byType('tool')]) assert.equal(item.parentObservationId, agentId)
    const generation = byType('generation')[0]
    assert.equal(generation.model, 'qwen3:0.6b')
    assert.deepEqual(generation.usage, { input: 50, output: 10, cachedInput: 0, total: 60 })
    assert.equal(generation.cost.billingType, 'local')
    assert.equal(generation.output, replies[0])
    assert.equal(requests[0].traceparent.split('-')[2], generation.id, 'the header names this generation')

    // The same trace through the Org's own routes, and a score on it.
    const scoped = (await org('GET', `/companies/${cid}/traces`)).json
    assert.equal(scoped.traces[0].id, summary.id)
    const score = await org('POST', `/companies/${cid}/traces/${summary.id}/scores`, { name: 'helpful', value: true, comment: 'Good run' })
    assert.equal(score.status, 201)
    assert.equal(score.json.dataType, 'BOOLEAN')
    const again = (await call(runtime.base, 'GET', `/api/traces/${summary.id}`)).json
    assert.equal(again.scores.length, 1)

    const byAgent = (await call(runtime.base, 'GET', '/api/traces/metrics?groupBy=agent&kind=org_run')).json
    assert.equal(byAgent.groups[0].key, lead.id)
    assert.equal(byAgent.groups[0].count, 1)
    assert.equal(byAgent.groups[0].usage.input, 200)
    const byModel = (await call(runtime.base, 'GET', '/api/traces/metrics?groupBy=model')).json
    assert.equal(byModel.groups.find((group) => group.key === 'qwen3:0.6b').count, 4)

    // Traces are owner-only files on disk.
    const dir = path.join(runtime.storage, 'state', 'traces')
    const files = readdirSync(dir).filter((name) => name.endsWith('.jsonl'))
    assert.equal(files.length, 1)
    assert.equal(statSync(path.join(dir, files[0])).mode & 0o077, 0)
  } finally {
    model.server.close()
    await stop(runtime)
  }
})

test('chat turns are traced, secrets are scrubbed, and the OTLP export reaches a collector', needsBinary, async () => {
  const lane = await listen(async (req, res) => {
    await readBody(req)
    res.writeHead(200, { 'content-type': 'application/json' })
    if (req.url === '/api/version') { res.end(JSON.stringify({ version: '0.0.0-test' })); return }
    res.end(JSON.stringify({ message: { role: 'assistant', content: 'Hi there.' }, prompt_eval_count: 12, eval_count: 3, done: true }))
  })
  const received = []
  const collector = await listen(async (req, res) => {
    received.push({ url: req.url, headers: req.headers, body: await readBody(req) })
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end('{}')
  })
  const runtime = await startRuntime({ OLLAMA_BASE_URL: lane.url, ROACHNET_INFERENCE_ENGINE: 'ollama' })
  try {
    const refused = await call(runtime.base, 'PUT', '/api/traces/settings', { export: { enabled: true, endpoint: 'http://example.com/otel' } })
    assert.equal(refused.status, 400, 'plain http off this Mac is refused')
    const settings = (await call(runtime.base, 'PUT', '/api/traces/settings', {
      export: { enabled: true, endpoint: `${collector.url}/api/public/otel`, headers: { Authorization: 'Basic cGs6c2s=' } },
    })).json
    assert.deepEqual(settings.export.headerNames, ['authorization'])
    assert.equal(JSON.stringify(settings).includes('cGs6c2s='), false, 'header values are write-only')

    const reply = await call(runtime.base, 'POST', '/api/ollama/chat', {
      model: 'qwen2.5:0.5b', stream: false,
      messages: [{ role: 'user', content: 'My key is sk-proj-abcdefghijklmnopqrstuvwxyz, say hi' }],
    })
    assert.equal(reply.json.message.content, 'Hi there.')
    const page = (await call(runtime.base, 'GET', '/api/traces?kind=chat&content=1')).json
    assert.equal(page.traces.length, 1)
    const chat = page.traces[0]
    assert.equal(chat.status, 'ok')
    assert.deepEqual(chat.usage, { input: 12, output: 3, cachedInput: 0, total: 15 })
    assert.equal(JSON.stringify(chat.input).includes('sk-proj-'), false, 'the key was scrubbed')
    assert.match(JSON.stringify(chat.input), /My key is \*\*\*/)

    const flush = (await call(runtime.base, 'POST', '/api/traces/export/flush')).json
    assert.equal(flush.ok, true, JSON.stringify(flush))
    assert.equal(received.length, 1)
    assert.equal(received[0].url, '/api/public/otel/v1/traces')
    assert.equal(received[0].headers.authorization, 'Basic cGs6c2s=')
    assert.equal(received[0].headers['x-langfuse-ingestion-version'], '4')
    const spans = received[0].body.resourceSpans[0].scopeSpans[0].spans
    const generation = spans.find((span) => attribute(span, 'langfuse.observation.type') === 'generation')
    assert.equal(generation.traceId, chat.id)
    assert.match(generation.spanId, /^[0-9a-f]{16}$/)
    assert.equal(attribute(generation, 'gen_ai.usage.input_tokens'), '12')
    assert.equal(attribute(generation, 'gen_ai.request.model'), 'qwen2.5:0.5b')
    assert.equal(attribute(generation, 'langfuse.trace.name'), 'RoachClaw chat · qwen2.5:0.5b')
    assert.equal(attribute(generation, 'langfuse.observation.input'), undefined, 'content stays home unless included')
    assert.equal(received[0].body.resourceSpans[0].resource.attributes.find((a) => a.key === 'service.name').value.stringValue, 'roachnet')

    // Turning content capture off keeps prompts out of new traces.
    await call(runtime.base, 'PUT', '/api/traces/settings', { captureContent: false, export: { enabled: false } })
    await call(runtime.base, 'POST', '/api/ollama/chat', { model: 'qwen2.5:0.5b', stream: false, messages: [{ role: 'user', content: 'private' }] })
    const quiet = (await call(runtime.base, 'GET', '/api/traces?kind=chat&content=1&limit=1')).json.traces[0]
    assert.equal(quiet.input, null)
    assert.equal(quiet.usage.total, 15)

    const deleted = await call(runtime.base, 'DELETE', `/api/traces/${quiet.id}`)
    assert.equal(deleted.status, 200)
    assert.equal((await call(runtime.base, 'GET', `/api/traces/${quiet.id}`)).status, 404)
  } finally {
    lane.server.close()
    collector.server.close()
    await stop(runtime)
  }
})
