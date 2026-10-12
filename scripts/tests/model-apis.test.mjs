// Contract tests for every model API RoachNet serves, on a real model:
// Ollama chat/generate/embed/create, OpenAI chat/completions/responses/
// embeddings and Anthropic messages, with tools, structured output and
// thinking. Needs ROACHNET_NATIVE_API_BINARY and ROACHNET_TEST_MODELS
// (qwen3-0.6b-q8_0.gguf).
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import test, { after, before } from 'node:test'
import { fileURLToPath } from 'node:url'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const binary = process.env.ROACHNET_NATIVE_API_BINARY?.trim() || ''
const modelDir = process.env.ROACHNET_TEST_MODELS?.trim() || ''
const qwen = modelDir ? path.join(modelDir, 'qwen3-0.6b-q8_0.gguf') : ''
const needsModel = binary && qwen && existsSync(qwen) ? {} : { skip: 'Set ROACHNET_NATIVE_API_BINARY and ROACHNET_TEST_MODELS (qwen3-0.6b-q8_0.gguf).' }
const MODEL = 'qwen3:0.6b'

async function freePort() {
  return new Promise((resolve) => {
    const server = net.createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

let runtime
async function start(extraEnv = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'rn-model-apis-'))
  const storage = path.join(root, 'storage')
  // Served in place from an Ollama-style folder, as an existing install would be.
  const digest = createHash('sha256').update(readFileSync(qwen)).digest('hex')
  const ollama = path.join(storage, 'models', 'ollama')
  mkdirSync(path.join(ollama, 'blobs'), { recursive: true })
  mkdirSync(path.join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'qwen3'), { recursive: true })
  symlinkSync(qwen, path.join(ollama, 'blobs', `sha256-${digest}`))
  writeFileSync(path.join(ollama, 'manifests', 'registry.ollama.ai', 'library', 'qwen3', '0.6b'), JSON.stringify({
    layers: [{ mediaType: 'application/vnd.ollama.image.model', digest: `sha256:${digest}`, size: readFileSync(qwen).length }],
  }))
  const port = await freePort()
  const child = spawn(binary, [], {
    env: {
      PATH: process.env.PATH, HOME: root, HOST: '127.0.0.1', PORT: '0', ROACHNET_REPO_ROOT: repoRoot,
      ROACHNET_STORAGE_PATH: storage, ROACHNET_COMPANION_ENABLED: '0', OLLAMA_BASE_URL: `http://127.0.0.1:${port}`,
      ...extraEnv,
    },
    stdio: 'ignore',
  })
  const base = `http://127.0.0.1:${port}`
  for (let i = 0; i < 150; i += 1) {
    try {
      if ((await fetch(`${base}/api/version`)).ok) return { root, base, child }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  child.kill('SIGTERM')
  throw new Error('native model server did not start')
}

const post = (route, body, headers = {}) => fetch(`${runtime.base}${route}`, { method: 'POST', headers, body: JSON.stringify(body) })
const json = async (route, body) => {
  const response = await post(route, body)
  const value = await response.json()
  assert.equal(response.status, 200, JSON.stringify(value))
  return value
}
const ndjson = async (route, body) => (await (await post(route, body)).text()).trim().split('\n').map((line) => JSON.parse(line))
const events = async (route, body) => (await (await post(route, body)).text()).split('\n\n').filter(Boolean).map((block) => {
  const event = /^event: (.*)$/m.exec(block)?.[1]
  const data = /^data: (.*)$/m.exec(block)?.[1]
  return { event, data: data === '[DONE]' ? '[DONE]' : JSON.parse(data) }
})
const norm = (vector) => Math.sqrt(vector.reduce((sum, value) => sum + value * value, 0))

const weatherTool = {
  type: 'function',
  function: {
    name: 'get_weather', description: 'Current weather for a city',
    parameters: { type: 'object', properties: { city: { type: 'string' } }, required: ['city'] },
  },
}
const greedy = { temperature: 0, seed: 1 }

before(async () => { if (!needsModel.skip) runtime = await start() })
after(async () => {
  if (!runtime) return
  runtime.child.kill('SIGTERM')
  await rm(runtime.root, { recursive: true, force: true })
})

test('Ollama chat: structured output, thinking and tool calls', needsModel, async () => {
  const schema = { type: 'object', properties: { city: { type: 'string' }, population: { type: 'integer' } }, required: ['city', 'population'] }
  const structured = await json('/api/chat', {
    model: MODEL, stream: false, format: schema, options: { ...greedy, num_predict: 80 },
    messages: [{ role: 'user', content: 'Give the capital of Norway and a rough population as JSON.' }],
  })
  const value = JSON.parse(structured.message.content)
  assert.equal(typeof value.city, 'string')
  assert.ok(Number.isInteger(value.population))
  assert.equal(structured.message.thinking, undefined, 'a format answers without thinking unless asked')

  const thought = await json('/api/chat', {
    model: MODEL, stream: false, think: true, options: { ...greedy, num_predict: 400 },
    messages: [{ role: 'user', content: 'What is 7 times 6? Answer with the number.' }],
  })
  assert.ok(thought.message.thinking?.length > 0, 'thinking comes back on its own')
  assert.ok(!thought.message.content.includes('<think>'))

  const lines = await ndjson('/api/chat', {
    model: MODEL, think: false, tools: [weatherTool], options: { ...greedy, num_predict: 80 },
    messages: [{ role: 'user', content: 'What is the weather in Oslo right now? Use the tool.' }],
  })
  const final = lines.at(-1)
  assert.equal(final.done, true)
  const calls = lines.flatMap((line) => line.message?.tool_calls ?? [])
  assert.equal(calls[0]?.function.name, 'get_weather')
  assert.match(calls[0].function.arguments.city, /oslo/i)
  assert.ok(lines.every((line) => !(line.message?.content ?? '').includes('<tool_call>')), 'calls never leak into content')

  const answered = await json('/api/chat', {
    model: MODEL, stream: false, think: false, tools: [weatherTool], options: { ...greedy, num_predict: 60 },
    messages: [{ role: 'user', content: 'What is the weather in Oslo right now? Use the tool.' },
      { role: 'assistant', content: '', tool_calls: [{ function: { name: 'get_weather', arguments: { city: 'Oslo' } } }] },
      { role: 'tool', tool_name: 'get_weather', content: '{"temperature_c": 4, "sky": "rain"}' }],
  })
  assert.match(answered.message.content, /4|rain/i, 'the tool result reaches the model')
})

test('Ollama generate: raw prompts, JSON mode and load-only calls', needsModel, async () => {
  const raw = await json('/api/generate', { model: MODEL, prompt: 'The capital of France is', raw: true, stream: false, options: { ...greedy, num_predict: 4 } })
  assert.match(raw.response, /Paris/)
  assert.equal(raw.eval_count, 4)
  const mode = await json('/api/generate', { model: MODEL, prompt: 'List two colors.', format: 'json', stream: false, options: { ...greedy, num_predict: 60 } })
  assert.equal(typeof JSON.parse(mode.response), 'object')
  const loaded = await json('/api/generate', { model: MODEL })
  assert.equal(loaded.done_reason, 'load')
})

test('OpenAI chat completions: forced tool call streamed, usage and errors', needsModel, async () => {
  const stream = await events('/v1/chat/completions', {
    model: MODEL, stream: true, stream_options: { include_usage: true }, temperature: 0, max_tokens: 60,
    tools: [weatherTool], tool_choice: { type: 'function', function: { name: 'get_weather' } },
    messages: [{ role: 'user', content: 'Weather in Bergen?' }],
  })
  assert.equal(stream.at(-1).data, '[DONE]')
  const chunks = stream.slice(0, -1).map((item) => item.data)
  const call = chunks.flatMap((chunk) => chunk.choices?.[0]?.delta?.tool_calls ?? [])[0]
  assert.equal(call.function.name, 'get_weather')
  assert.equal(typeof JSON.parse(call.function.arguments).city, 'string')
  assert.equal(chunks.find((chunk) => chunk.choices?.[0]?.finish_reason)?.choices[0].finish_reason, 'tool_calls')
  assert.ok(chunks.at(-1).usage.prompt_tokens > 0)

  const whole = await json('/v1/chat/completions', {
    model: MODEL, temperature: 0, max_tokens: 60, reasoning_effort: 'none',
    response_format: { type: 'json_schema', json_schema: { name: 'a', schema: { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'] } } },
    messages: [{ role: 'user', content: 'Is water wet? Reply in JSON.' }],
  })
  assert.equal(typeof JSON.parse(whole.choices[0].message.content).ok, 'boolean')
  assert.equal(whole.choices[0].finish_reason, 'stop')

  const missing = await post('/v1/chat/completions', { model: 'nope:1b', messages: [{ role: 'user', content: 'hi' }] })
  assert.equal(missing.status, 404)
  assert.equal(typeof (await missing.json()).error.message, 'string')
  assert.equal((await (await fetch(`${runtime.base}/v1/models/${MODEL}`)).json()).id, MODEL)
})

test('OpenAI completions and responses', needsModel, async () => {
  const completion = await json('/v1/completions', { model: MODEL, prompt: 'The capital of France is', max_tokens: 4, temperature: 0 })
  assert.equal(completion.object, 'text_completion')
  assert.match(completion.choices[0].text, /Paris/)

  const response = await json('/v1/responses', {
    model: MODEL, instructions: 'Answer briefly.', input: 'Name a primary color.', max_output_tokens: 60, reasoning: { effort: 'none' },
    text: { format: { type: 'json_schema', name: 'c', schema: { type: 'object', properties: { color: { type: 'string' } }, required: ['color'] } } },
  })
  assert.equal(response.object, 'response')
  assert.equal(response.status, 'completed')
  const message = response.output.find((item) => item.type === 'message')
  assert.equal(typeof JSON.parse(message.content[0].text).color, 'string')
  assert.ok(response.usage.input_tokens > 0)

  const streamed = await events('/v1/responses', {
    model: MODEL, input: [{ role: 'user', content: [{ type: 'input_text', text: 'Weather in Oslo?' }] }], stream: true, max_output_tokens: 60,
    tools: [{ type: 'function', name: 'get_weather', parameters: weatherTool.function.parameters }], tool_choice: 'required',
  })
  const types = streamed.map((item) => item.event)
  assert.equal(types[0], 'response.created')
  assert.equal(types.at(-1), 'response.completed')
  assert.ok(types.includes('response.function_call_arguments.done'))
  assert.deepEqual(streamed.map((item) => item.data.sequence_number), streamed.map((_, index) => index))
  const done = streamed.at(-1).data.response
  assert.equal(done.output.find((item) => item.type === 'function_call').name, 'get_weather')
})

test('Anthropic messages: text, tool use, streaming and token counts', needsModel, async () => {
  const reply = await json('/v1/messages', {
    model: MODEL, max_tokens: 30, thinking: { type: 'disabled' }, system: 'Reply in one short sentence.',
    messages: [{ role: 'user', content: 'Say hello.' }],
  })
  assert.equal(reply.type, 'message')
  assert.equal(reply.content[0].type, 'text')
  assert.ok(['end_turn', 'max_tokens'].includes(reply.stop_reason))
  assert.ok(reply.usage.input_tokens + reply.usage.cache_read_input_tokens > 0)

  const streamed = await events('/v1/messages', {
    model: MODEL, max_tokens: 60, stream: true, tools: [{ name: 'get_weather', input_schema: weatherTool.function.parameters }],
    tool_choice: { type: 'tool', name: 'get_weather' }, messages: [{ role: 'user', content: 'Weather in Oslo?' }],
  })
  const types = streamed.map((item) => item.event)
  assert.equal(types[0], 'message_start')
  assert.equal(types.at(-1), 'message_stop')
  const start = streamed.find((item) => item.data.content_block?.type === 'tool_use')
  assert.equal(start.data.content_block.name, 'get_weather')
  const json_ = streamed.find((item) => item.data.delta?.type === 'input_json_delta').data.delta.partial_json
  assert.equal(typeof JSON.parse(json_).city, 'string')
  assert.equal(streamed.find((item) => item.event === 'message_delta').data.delta.stop_reason, 'tool_use')

  const counted = await json('/v1/messages/count_tokens', { model: MODEL, messages: [{ role: 'user', content: 'Hello there' }] })
  assert.ok(counted.input_tokens > 3)
  const missing = await post('/v1/messages', { model: 'nope:1b', max_tokens: 5, messages: [{ role: 'user', content: 'hi' }] })
  assert.equal((await missing.json()).error.type, 'not_found_error')
})

test('embeddings on all three routes', needsModel, async () => {
  const ollama = await json('/api/embed', { model: MODEL, input: ['red apple', 'green pear'] })
  assert.equal(ollama.embeddings.length, 2)
  assert.equal(ollama.embeddings[0].length, ollama.embeddings[1].length)
  assert.ok(Math.abs(norm(ollama.embeddings[0]) - 1) < 1e-3)
  assert.ok(ollama.prompt_eval_count > 0)

  const legacy = await json('/api/embeddings', { model: MODEL, prompt: 'red apple' })
  assert.equal(legacy.embedding.length, ollama.embeddings[0].length)

  const openai = await json('/v1/embeddings', { model: MODEL, input: 'red apple', dimensions: 64 })
  assert.equal(openai.data[0].embedding.length, 64)
  assert.ok(Math.abs(norm(openai.data[0].embedding) - 1) < 1e-3)
  const packed = await json('/v1/embeddings', { model: MODEL, input: ['a', 'b'], encoding_format: 'base64' })
  assert.equal(Buffer.from(packed.data[1].embedding, 'base64').length, ollama.embeddings[0].length * 4)
  assert.equal(packed.data[1].index, 1)
})

test('create, show, copy and delete made models without copying weights', needsModel, async () => {
  const lines = await ndjson('/api/create', {
    model: 'pirate:latest', from: MODEL, system: 'You are a pirate. Always say Arr.', parameters: { temperature: 0, num_predict: 24 },
  })
  assert.equal(lines.at(-1).status, 'success')
  const legacy = await json('/api/create', { model: 'terse', stream: false, modelfile: `FROM ${MODEL}\nSYSTEM """Answer in one word."""\nPARAMETER stop "."` })
  assert.equal(legacy.status, 'success')

  const shown = await json('/api/show', { model: 'pirate' })
  assert.match(shown.modelfile, /FROM qwen3:0\.6b/)
  assert.equal(shown.system, 'You are a pirate. Always say Arr.')
  assert.match(shown.parameters, /temperature 0/)
  assert.ok(shown.capabilities.includes('tools') && shown.capabilities.includes('thinking'))
  const tags = await (await fetch(`${runtime.base}/api/tags`)).json()
  assert.equal(tags.models.find((model) => model.name === 'pirate:latest').details.parent_model, MODEL)

  const said = await json('/api/chat', { model: 'pirate', stream: false, think: false, messages: [{ role: 'user', content: 'Greet me.' }] })
  assert.equal(said.eval_count <= 24, true, "the made model's parameters apply")
  await json('/api/chat', { model: MODEL, stream: false, think: false, messages: [{ role: 'user', content: 'Hi' }], options: { num_predict: 2 } })
  const ps = await (await fetch(`${runtime.base}/api/ps`)).json()
  assert.equal(ps.models.length, 1, 'a made model runs on its base model\'s engine')

  assert.equal((await post('/api/copy', { source: 'pirate', destination: 'pirate2' })).status, 200)
  assert.equal((await (await post('/api/show', { model: 'pirate2' })).json()).system, 'You are a pirate. Always say Arr.')
  assert.equal((await fetch(`${runtime.base}/api/delete`, { method: 'DELETE', body: JSON.stringify({ model: 'pirate' }) })).status, 200)
  assert.equal((await post('/api/show', { model: 'pirate2' })).status, 200, 'a copy outlives the model it came from')
  assert.equal((await post('/api/show', { model: MODEL })).status, 200)
  assert.equal((await post('/api/create', { model: 'x', from: '/nope/model.gguf' })).status, 400)
  assert.equal((await post('/api/create', { model: 'x', from: MODEL, quantize: 'q4_K_M' })).status, 400)
})

test('models are fitted into memory: a shorter context first, then a clear refusal', needsModel, async () => {
  for (const [budget, expect] of [['1.4', 'fits'], ['0.3', 'refused']]) {
    const tight = await start({ ROACHNET_MODEL_MEMORY_GB: budget })
    try {
      const response = await fetch(`${tight.base}/api/chat`, {
        method: 'POST',
        body: JSON.stringify({ model: MODEL, stream: false, think: false, messages: [{ role: 'user', content: 'Hi' }], options: { num_predict: 2, num_ctx: 8192 } }),
      })
      const body = await response.json()
      if (expect === 'fits') {
        assert.equal(response.status, 200, JSON.stringify(body))
        const ps = await (await fetch(`${tight.base}/api/ps`)).json()
        assert.ok(ps.models[0].context_length < 8192, 'the context was shortened to fit')
        assert.ok(ps.models[0].size_vram > 0)
      } else {
        assert.equal(response.status, 507)
        assert.match(body.error, /needs about .* GB of memory/)
      }
    } finally {
      tight.child.kill('SIGTERM')
      await rm(tight.root, { recursive: true, force: true })
    }
  }
})

test('requests run side by side in slots, and each conversation keeps its cache', needsModel, async () => {
  const own = await start()
  try {
    const options = { ...greedy, num_ctx: 2048, num_predict: 48 }
    const ask = (content, extra = {}) => ({ model: MODEL, stream: false, think: false, options, messages: [{ role: 'user', content }], ...extra })
    const call = async (body, base = own.base) => {
      const response = await fetch(`${base}/api/chat`, { method: 'POST', body: JSON.stringify(body) })
      const value = await response.json()
      assert.equal(response.status, 200, JSON.stringify(value))
      return value
    }
    const a = ask('Count from one to forty in words, separated by commas.')
    const b = ask('List the planets of the solar system, one per line.')
    const firstA = await call(a)
    const firstB = await call(b)

    // Both again at once: each lands in the slot that already holds it.
    const timeline = []
    const watch = async (label, body) => {
      const response = await fetch(`${own.base}/api/chat`, { method: 'POST', body: JSON.stringify({ ...body, stream: true }) })
      const reader = response.body.getReader()
      const decoder = new TextDecoder()
      let buffered = ''
      let text = ''
      let last
      for (;;) {
        const { value, done } = await reader.read()
        if (done) break
        buffered += decoder.decode(value, { stream: true })
        let newline
        while ((newline = buffered.indexOf('\n')) >= 0) {
          const line = buffered.slice(0, newline)
          buffered = buffered.slice(newline + 1)
          if (!line.trim()) continue
          last = JSON.parse(line)
          if (last.message?.content) {
            text += last.message.content
            timeline.push([label, performance.now()])
          }
        }
      }
      return { text, last }
    }
    const [againA, againB] = await Promise.all([watch('a', a), watch('b', b)])
    assert.equal(againA.text, firstA.message.content, 'a slot gives the same greedy answer')
    assert.equal(againB.text, firstB.message.content)
    assert.equal(againA.last.prompt_eval_count, 1, "conversation A's prompt was already cached in its slot")
    assert.equal(againB.last.prompt_eval_count, 1, "and B's in its own")
    const endA = Math.max(...timeline.filter(([label]) => label === 'a').map(([, at]) => at))
    const endB = Math.max(...timeline.filter(([label]) => label === 'b').map(([, at]) => at))
    const startA = Math.min(...timeline.filter(([label]) => label === 'a').map(([, at]) => at))
    const startB = Math.min(...timeline.filter(([label]) => label === 'b').map(([, at]) => at))
    assert.ok(startB < endA && startA < endB, 'the two replies streamed at the same time')

    const ps = await (await fetch(`${own.base}/api/ps`)).json()
    assert.equal(ps.models.length, 1)
    assert.equal(ps.models[0].slots, 2)

    // A follow-up to A goes to A's slot and reuses what still matches (Qwen3
    // renders a past reply without its empty think block, so not all of it).
    const followUp = await call({
      ...a,
      messages: [...a.messages, { role: 'assistant', content: firstA.message.content }, { role: 'user', content: 'Now in French.' }],
    })
    assert.ok(followUp.prompt_eval_count < firstA.prompt_eval_count + firstA.eval_count,
      `the cached start of the conversation was reused (${followUp.prompt_eval_count} tokens evaluated)`)
    assert.equal((await (await fetch(`${own.base}/api/ps`)).json()).models[0].slots, 2, 'no new slot for the next turn')

    // A second agent with the same long system prompt starts from a copy of
    // it in a new slot, and the first agent keeps its own conversation.
    const system = 'You are a careful assistant for the RoachNet project. '.repeat(8)
    const c = { ...a, messages: [{ role: 'system', content: system }, { role: 'user', content: 'Say hi.' }] }
    const d = { ...a, messages: [{ role: 'system', content: system }, { role: 'user', content: 'Say bye in Spanish.' }] }
    const firstC = await call(c)
    const forked = await call(d)
    assert.ok(forked.prompt_eval_count * 3 < firstC.prompt_eval_count, `the shared system prompt was copied (${forked.prompt_eval_count} evaluated)`)
    assert.equal((await call(c)).prompt_eval_count, 1, 'the first agent kept its conversation')

    // The copied prefix answers exactly as a computed one; one slot serializes.
    const serial = await start({ ROACHNET_MODEL_SLOTS: '1' })
    try {
      assert.equal((await call(d, serial.base)).message.content, forked.message.content)
      await call(a, serial.base)
      const one = await (await fetch(`${serial.base}/api/ps`)).json()
      assert.equal(one.models[0].slots, 1)
    } finally {
      serial.child.kill('SIGTERM')
      await rm(serial.root, { recursive: true, force: true })
    }
  } finally {
    own.child.kill('SIGTERM')
    await rm(own.root, { recursive: true, force: true })
  }
})
