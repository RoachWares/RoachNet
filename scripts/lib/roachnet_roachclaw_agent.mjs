import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'

export const ROACHCLAW_NATIVE_AGENT_RUNTIME = 'roachclaw-native-agent'
export const ROACHCLAW_AGENT_REVIEWED_HERMES_HEAD = '5fc308a70719a83cccdbba4c0e39c23f5a8239d5'

export const ROACHCLAW_AGENT_SKILLS = Object.freeze([
  {
    id: 'app-context-router',
    title: 'App context router',
    description: 'Builds a permissioned context packet from the current RoachNet surface.',
    runtime: 'roachclaw-native',
  },
  {
    id: 'dev-agent',
    title: 'Dev agent',
    description: 'Uses visible editor, terminal, diagnostics, and release-gate context for coding work.',
    runtime: 'roachclaw-native',
  },
  {
    id: 'vault-research',
    title: 'Vault research',
    description: 'Indexes local notes, books, media, and archive records without hidden cloud custody.',
    runtime: 'roachclaw-native',
  },
  {
    id: 'arcade-copilot',
    title: 'Arcade copilot',
    description: 'Explains games, mods, controllers, emulators, save state, and cheat context inside RoachArcade.',
    runtime: 'roachclaw-native',
  },
  {
    id: 'release-gate-operator',
    title: 'Release gate operator',
    description: 'Turns build, installer, update, and public-surface checks into explicit verification packets.',
    runtime: 'roachclaw-native',
  },
  {
    id: 'memory-curator',
    title: 'Memory curator',
    description: 'Reads and writes RoachBrain records under the user-owned RoachNet storage root.',
    runtime: 'roachclaw-native',
  },
])

const DEFAULT_ENABLED_SCOPES = Object.freeze(['roachnet'])
const SCOPE_LABELS = Object.freeze({
  roachnet: 'RoachNet shell',
  dev: 'Dev workspace',
  vault: 'Vault',
  archives: 'Captured archives',
  arcade: 'RoachArcade',
  maps: 'Maps',
  media: 'Media',
  settings: 'Settings',
  runtime: 'Runtime',
})

function cleanString(value) {
  return String(value ?? '').trim()
}

function cleanScope(value) {
  return cleanString(value).toLowerCase().replace(/[^a-z0-9_-]/g, '')
}

function uniq(values) {
  const out = []
  const seen = new Set()
  for (const value of values) {
    const normalized = cleanScope(value)
    if (!normalized || seen.has(normalized)) continue
    seen.add(normalized)
    out.push(normalized)
  }
  return out
}

function clampInt(value, fallback, min, max) {
  const parsed = Number.parseInt(String(value ?? ''), 10)
  if (!Number.isFinite(parsed)) return fallback
  return Math.max(min, Math.min(max, parsed))
}

function safeContextValue(value, maxCharacters) {
  if (value === null || value === undefined) return ''
  const raw = typeof value === 'string' ? value : JSON.stringify(value, null, 2)
  const normalized = raw.replace(/\s+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim()
  return normalized.length > maxCharacters
    ? `${normalized.slice(0, Math.max(0, maxCharacters - 32)).trimEnd()}\n[truncated locally]`
    : normalized
}

export function roachClawAgentWorkspace(storageRoot) {
  return path.join(storageRoot, 'RoachClaw')
}

function roachClawAgentStateDirectory(storageRoot) {
  return path.join(roachClawAgentWorkspace(storageRoot || process.cwd()), 'agent')
}

function roachClawAgentStatePath(storageRoot) {
  return path.join(roachClawAgentStateDirectory(storageRoot), 'state.json')
}

function defaultAgentState() {
  return {
    schemaVersion: 1,
    memories: [],
  }
}

export function defaultRoachClawAgentSkills() {
  return ROACHCLAW_AGENT_SKILLS.map((skill) => ({ ...skill }))
}

export function loadRoachClawAgentState({ storageRoot } = {}) {
  const statePath = roachClawAgentStatePath(storageRoot || process.cwd())
  if (!existsSync(statePath)) {
    return defaultAgentState()
  }

  try {
    const parsed = JSON.parse(readFileSync(statePath, 'utf8'))
    return {
      ...defaultAgentState(),
      ...parsed,
      memories: Array.isArray(parsed.memories) ? parsed.memories : [],
    }
  } catch {
    return defaultAgentState()
  }
}

function writeRoachClawAgentState(storageRoot, state) {
  const stateDirectory = roachClawAgentStateDirectory(storageRoot || process.cwd())
  mkdirSync(stateDirectory, { recursive: true })
  writeFileSync(roachClawAgentStatePath(storageRoot || process.cwd()), `${JSON.stringify(state, null, 2)}\n`)
}

export function recordRoachClawAgentMemory({
  storageRoot,
  source = 'RoachNet',
  prompt = '',
  response = '',
  tags = [],
} = {}) {
  const cleanTags = Array.isArray(tags) ? uniq(tags).slice(0, 12) : []
  const record = {
    id: `rnmem_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`,
    source: cleanString(source) || 'RoachNet',
    prompt: cleanString(prompt),
    response: cleanString(response),
    tags: cleanTags,
    createdAt: new Date().toISOString(),
  }
  const state = loadRoachClawAgentState({ storageRoot })
  state.memories = [record, ...state.memories].slice(0, 250)
  writeRoachClawAgentState(storageRoot, state)
  return record
}

export function roachClawNativeAgentStatus({
  storageRoot,
  defaultModel = 'qwen2.5-coder:1.5b',
  resolvedDefaultModel = defaultModel,
  installedModels = [],
  ollamaAvailable = false,
} = {}) {
  const workspacePath = roachClawAgentWorkspace(storageRoot || process.cwd())
  const modelReady = Array.isArray(installedModels) && installedModels.includes(resolvedDefaultModel || defaultModel)

  return {
    runtime: ROACHCLAW_NATIVE_AGENT_RUNTIME,
    mode: 'native-rewrite',
    upstreamRuntimeDependency: 'none',
    localOnly: true,
    ready: Boolean(ollamaAvailable && modelReady),
    workspacePath,
    defaultModel,
    resolvedDefaultModel,
    skills: defaultRoachClawAgentSkills(),
    policy: {
      defaultExecutionMode: 'plan-only',
      requiresApprovalFor: [
        'shell.write',
        'file.write',
        'network',
        'browser',
        'installer',
        'destructive',
      ],
    },
    toolPolicy: {
      defaultExecutionMode: 'plan-only',
      approvalRequiredFor: ['shell', 'file-write', 'network', 'browser', 'installer', 'destructive'],
      deniedByDefault: ['credential-exfiltration', 'silent-network-sync', 'unreviewed-destructive-action'],
    },
    budgets: {
      contextCharacters: 12_000,
      planMaxTokens: 4_096,
      evaluatorMaxTokens: 4_096,
      maxToolLoopAttempts: 3,
    },
    memory: {
      provider: 'roachbrain',
      storagePath: path.join(storageRoot || process.cwd(), 'roachbrain'),
      profileIsolation: 'per-storage-root',
    },
    references: {
      hermesAgent: {
        role: 'design-reference-only',
        reviewedHead: ROACHCLAW_AGENT_REVIEWED_HERMES_HEAD,
        upstreamRuntimeDependency: false,
        vendoredCode: false,
      },
      openClaw: {
        role: 'migration-reference-only',
        bundledRuntime: false,
      },
    },
  }
}

export function buildRoachClawAgentPrompt(body = {}, status = roachClawNativeAgentStatus()) {
  const prompt = cleanString(body.prompt || body.userPrompt)
  if (!prompt) {
    throw new Error('RoachClaw agent prompt is required.')
  }

  const contextBudget = clampInt(
    body.contextBudget || body.budgetCharacters,
    status.budgets?.contextCharacters || 12_000,
    1_000,
    64_000
  )
  const enabledScopes = uniq(Array.isArray(body.enabledScopes) ? body.enabledScopes : DEFAULT_ENABLED_SCOPES)
  const context = body.context && typeof body.context === 'object' ? body.context : {}
  const activeSurface = cleanString(body.activeSurface) || cleanString(body.surface) || 'RoachNet'
  const perScopeBudget = Math.max(600, Math.floor(contextBudget / Math.max(1, enabledScopes.length)))

  const contextLines = []
  for (const scope of enabledScopes) {
    const value = context[scope]
    const excerpt = safeContextValue(value, perScopeBudget)
    if (!excerpt) continue
    contextLines.push(`## ${SCOPE_LABELS[scope] || scope}\n${excerpt}`)
  }

  const contextBlock = contextLines.length > 0
    ? contextLines.join('\n\n')
    : 'No permissioned context supplied. Ask for access before relying on hidden app state.'

  return {
    model: cleanString(body.model) || status.resolvedDefaultModel || status.defaultModel,
    messages: [
      {
        role: 'system',
        content: [
          "RoachClaw is RoachNet's native local agent spine.",
          'Use only the permissioned context in this packet.',
          'Name the smallest useful next action.',
          'Never claim a command ran, a file changed, or a release shipped unless a RoachNet tool lane performed it.',
          'Request approval before shell, file-write, network, browser, installer, or destructive actions.',
        ].join('\n'),
      },
      {
        role: 'user',
        content: [
          `Task: ${prompt}`,
          `Active surface: ${activeSurface}`,
          `Enabled scopes: ${enabledScopes.join(', ') || 'none'}`,
          '',
          'Permissioned context:',
          contextBlock,
        ].join('\n'),
      },
    ],
    enabledScopes,
    includedScopes: enabledScopes.filter((scope) => Boolean(safeContextValue(context[scope], perScopeBudget))),
    activeSurface,
    contextCharacters: contextBlock.length,
  }
}

export function createRoachClawAgentRuntime({ storageRoot, defaultModel = 'qwen2.5-coder:1.5b' } = {}) {
  return {
    runtime: ROACHCLAW_NATIVE_AGENT_RUNTIME,
    storageRoot: storageRoot || process.cwd(),
    defaultModel,
    status(options = {}) {
      return roachClawNativeAgentStatus({
        storageRoot: storageRoot || process.cwd(),
        defaultModel,
        resolvedDefaultModel: options.resolvedDefaultModel || defaultModel,
        installedModels: options.installedModels || [],
        ollamaAvailable: options.ollamaAvailable === true,
      })
    },
    buildPrompt(body = {}) {
      return buildRoachClawAgentPrompt({ ...body, prompt: body.prompt || body.userPrompt }, this.status())
    },
    run(body = {}) {
      return createRoachClawAgentRun(body, this.status())
    },
  }
}

export function createRoachClawAgentRun(body = {}, status = roachClawNativeAgentStatus()) {
  const prompt = buildRoachClawAgentPrompt(body, status)
  const requestedExecution = body.execute === true
  const safePlanOnly = !requestedExecution

  return {
    runtime: ROACHCLAW_NATIVE_AGENT_RUNTIME,
    upstreamRuntimeDependency: 'none',
    executed: false,
    executionMode: safePlanOnly ? 'plan-only' : 'approval-required',
    prompt,
    plan: {
      summary: requestedExecution
        ? 'Prepared a native RoachClaw agent packet. Execution is blocked until explicit tool approval is wired for this action.'
        : 'Prepared a native RoachClaw agent packet without executing tools.',
      steps: [
        'Read only the permissioned RoachNet context.',
        'Draft the smallest useful response or tool plan.',
        'Ask for approval before any shell, file-write, network, browser, installer, or destructive action.',
        'Record useful outcomes back into local RoachBrain memory after verification.',
      ],
    },
    toolPolicy: status.toolPolicy,
    budgets: status.budgets,
  }
}
