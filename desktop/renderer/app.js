const desktop = window.roachnetDesktop
const root = document.querySelector('#app')

const state = {
  desktopState: null,
  aiState: null,
  knowledgeState: null,
  draftConfig: null,
  aiDraft: null,
  activeSessionId: null,
  activeSession: null,
  chatInput: '',
  modelSearchQuery: '',
  skillSearchQuery: '',
  modelSearchResults: null,
  skillSearchResults: null,
  error: '',
  busyAction: '',
  autoLaunchedTaskId: null,
  introVisible: false,
  introTimerStarted: false,
  roachClawBootstrapStarted: false,
  roachCastOpen: false,
  roachCastQuery: '',
  roachCastSelectedIndex: 0,
  activePane: 'overview',
  introStepIndex: 0,
}

let lastRenderedMarkup = ''

const ROACHNET_TOUR_STEPS = [
  {
    id: 'contained',
    kicker: 'Contained install',
    title: 'RoachNet keeps the suite together.',
    body: 'The app, runtime data, storage, and RoachClaw workspace stay grouped around the install root whenever the platform allows it.',
  },
  {
    id: 'roachclaw',
    kicker: 'RoachClaw',
    title: 'Local AI starts on one path.',
    body: 'Ollama and OpenClaw are prepared together so OpenClaw can default to a local Ollama model from the first run.',
  },
  {
    id: 'workspace',
    kicker: 'Native workspace',
    title: 'The workspace is built around the suite.',
    body: 'Setup, RoachClaw, model controls, chat, and knowledge tools live in one calmer desktop surface.',
  },
  {
    id: 'launch',
    kicker: 'RoachCast',
    title: 'Quick actions stay close.',
    body: 'Use the built-in launcher to move across setup, runtime, models, chat, and knowledge tools without leaving the suite.',
  },
]

let introAdvanceTimer = null
let introDismissTimer = null

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

function formatDate(value) {
  if (!value) {
    return 'Not yet'
  }

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) {
    return String(value)
  }

  return date.toLocaleString()
}

function clamp(value, min, max) {
  return Math.min(Math.max(value, min), max)
}

function createTaskId(task) {
  if (!task) {
    return null
  }

  return task.startedAt || task.finishedAt || task.result?.installPath || null
}

function getEffectiveConfig() {
  return state.draftConfig || state.desktopState?.setup?.config || state.desktopState?.config || {}
}

function getEffectiveAiDraft() {
  return state.aiDraft || {
    model: '',
    chatModel: '',
    workspacePath: '',
    ollamaBaseUrl: '',
    openclawBaseUrl: '',
  }
}

function getStatusTone(label) {
  switch (label) {
    case 'live':
    case 'completed':
    case 'ready':
    case 'available':
    case 'applied':
      return 'status-live'
    case 'booting':
    case 'checking':
    case 'downloading':
    case 'running':
    case 'queued':
      return 'status-progress'
    case 'warning':
    case 'setup':
    case 'pending':
      return 'status-standby'
    case 'error':
    case 'failed':
      return 'status-error'
    default:
      return 'status-idle'
  }
}

function statusPill(label, toneOverride) {
  const tone = toneOverride || getStatusTone(label)
  return `<span class="status-pill ${tone}">${escapeHtml(label)}</span>`
}

function getRuntimeStatus(runtime) {
  if (!runtime?.running) {
    return { label: 'offline', tone: 'status-offline' }
  }

  if (runtime.mode === 'app' && runtime.appHealth?.ok) {
    return { label: 'live', tone: 'status-live' }
  }

  if (runtime.mode === 'setup') {
    return { label: 'setup', tone: 'status-standby' }
  }

  return { label: 'running', tone: 'status-progress' }
}

function getSettledData(result, fallback = null) {
  return result?.ok ? result.data : fallback
}

function getSettledError(result) {
  return result && result.ok === false ? result.error : null
}

function getInstalledModels() {
  const models = getSettledData(state.aiState?.installedModels, [])
  return Array.isArray(models) ? models : []
}

function getInstalledSkills() {
  const payload = getSettledData(state.aiState?.installedSkills, { skills: [] })
  return Array.isArray(payload?.skills) ? payload.skills : []
}

function getChatSessions() {
  const sessions = getSettledData(state.aiState?.chatSessions, [])
  return Array.isArray(sessions) ? sessions : []
}

function getRoachClawStatus() {
  return getSettledData(state.aiState?.roachclaw, null)
}

function getSystemInfo() {
  return getSettledData(state.aiState?.systemInfo, null)
}

function getProviderStatus() {
  return getSettledData(state.aiState?.providers, { providers: {} })
}

function getChatSuggestions() {
  const payload = getSettledData(state.aiState?.chatSuggestions, { suggestions: [] })
  return Array.isArray(payload?.suggestions) ? payload.suggestions : []
}

function getKnowledgeFiles() {
  const payload = getSettledData(state.knowledgeState?.files, { files: [] })
  return Array.isArray(payload?.files) ? payload.files : []
}

function getKnowledgeJobs() {
  const jobs = getSettledData(state.knowledgeState?.activeJobs, [])
  return Array.isArray(jobs) ? jobs : []
}

function getAccelerationData() {
  return state.desktopState?.acceleration || null
}

function getSelectedChatModel() {
  const config = getEffectiveConfig()
  const aiDraft = getEffectiveAiDraft()
  const sessionModel = state.activeSession?.model
  const roachClaw = getRoachClawStatus()
  const firstInstalled = getInstalledModels()[0]?.name || ''

  if (config.distributedInferenceBackend === 'exo' && config.exoModelId) {
    return config.exoModelId
  }

  if (config.appleAccelerationBackend === 'mlx' && config.mlxModelId) {
    return config.mlxModelId
  }

  return aiDraft.chatModel || sessionModel || roachClaw?.defaultModel || firstInstalled
}

function getPreferredChatRouteLabel() {
  const config = getEffectiveConfig()
  const acceleration = getAccelerationData()

  if (config.distributedInferenceBackend === 'exo' && acceleration?.distributed?.exo?.reachable) {
    return 'exo cluster'
  }

  if (config.appleAccelerationBackend === 'mlx' && acceleration?.apple?.server?.reachable) {
    return 'mlx server'
  }

  return 'ollama local'
}

function openRoachCast() {
  state.roachCastOpen = true
  state.roachCastSelectedIndex = 0
  render()
}

function closeRoachCast() {
  state.roachCastOpen = false
  state.roachCastQuery = ''
  state.roachCastSelectedIndex = 0
  render()
}

function setRoachCastQuery(query) {
  state.roachCastQuery = query
  state.roachCastSelectedIndex = 0
  render()
}

function getRoachCastCommands() {
  const desktopState = state.desktopState || {}
  const runtime = desktopState.runtime || {}
  const install = desktopState.install || {}
  const installedModels = getInstalledModels()
  const chatSessions = getChatSessions()
  const aiDraft = getEffectiveAiDraft()
  const roachClaw = getRoachClawStatus()
  const selectedModel = getSelectedChatModel()

  const commands = [
    {
      id: 'start-app',
      title: 'Start Core Services',
      subtitle: 'Boot the RoachNet runtime and AI control plane.',
      detail: 'Starts the main local runtime so RoachClaw, chat, and knowledge tools are available.',
      group: 'Core',
      keywords: 'launch runtime start services roachnet',
      disabled: !install.installed,
      hint: install.installed ? 'Enter' : 'Install RoachNet first',
    },
    {
      id: 'stop-runtime',
      title: 'Stop Core Services',
      subtitle: 'Shut down the current RoachNet runtime.',
      detail: 'Stops the managed local runtime and clears the active AI workbench state.',
      group: 'Core',
      keywords: 'stop runtime services shutdown',
      disabled: !runtime.running,
      hint: runtime.running ? 'Enter' : 'Not running',
    },
    {
      id: 'open-installer-helper',
      title: 'Open RoachNet Setup',
      subtitle: 'Launch the separate installer and setup application.',
      detail: 'Hands off to the standalone setup helper instead of starting onboarding inside the main shell.',
      group: 'Core',
      keywords: 'setup installer helper onboarding',
      hint: 'Enter',
    },
    {
      id: 'check-updates',
      title: 'Check For Updates',
      subtitle: 'Poll the configured release feed and update channel.',
      detail: 'Uses the native updater controller to check the current release channel.',
      group: 'Core',
      keywords: 'updates updater release channel',
      hint: 'Enter',
    },
    {
      id: 'open-install-folder',
      title: 'Open Install Folder',
      subtitle: 'Reveal the live RoachNet installation in Finder or Explorer.',
      detail: 'Opens the configured install path for logs, configs, and recovery work.',
      group: 'Core',
      keywords: 'install folder finder explorer files',
      disabled: !install.installed,
      hint: install.installed ? 'Enter' : 'Install first',
    },
    {
      id: 'open-releases',
      title: 'Open Release Downloads',
      subtitle: 'Jump to packaged RoachNet downloads and release assets.',
      detail: 'Opens the release downloads page in the default browser.',
      group: 'Core',
      keywords: 'release downloads packages',
      hint: 'Enter',
    },
    {
      id: 'start-container-runtime',
      title: 'Start Container Runtime',
      subtitle: 'Boot Docker/Desktop orchestration for support services.',
      detail: 'Triggers the integrated RoachNet container runtime startup path.',
      group: 'Runtime',
      keywords: 'docker compose containers runtime support services',
      disabled: desktopState.setup?.containerRuntime?.ready,
      hint: desktopState.setup?.containerRuntime?.ready ? 'Already ready' : 'Enter',
    },
    {
      id: 'refresh-ai',
      title: 'Refresh AI Runtime',
      subtitle: 'Reload local provider status, models, skills, and sessions.',
      detail: 'Refreshes live provider status, installed models, skills, and active sessions.',
      group: 'AI',
      keywords: 'refresh ai runtime models providers skills',
      disabled: !state.aiState,
      hint: state.aiState ? 'Enter' : 'Start Core Services',
    },
    {
      id: 'apply-roachclaw',
      title: 'Apply RoachClaw Defaults',
      subtitle: `Bind OpenClaw to ${aiDraft.model || roachClaw?.defaultModel || 'the selected local model'}.`,
      detail: 'Saves the current Ollama, OpenClaw, and workspace defaults into the local RoachClaw profile.',
      group: 'AI',
      keywords: 'roachclaw openclaw ollama defaults apply workspace',
      disabled: !state.aiState || !(aiDraft.model || roachClaw?.defaultModel),
      hint: state.aiState ? 'Enter' : 'Start Core Services',
    },
    {
      id: 'search-models',
      title: 'Search Ollama Catalog',
      subtitle: 'Search the broader model library for downloads.',
      detail: 'Queries the model catalog so you can install additional local models.',
      group: 'AI',
      keywords: 'ollama model library search download install',
      disabled: !state.aiState,
      hint: state.aiState ? 'Enter' : 'Start Core Services',
    },
    {
      id: 'search-models-recommended',
      title: 'Search Recommended Models',
      subtitle: 'Use RoachNet hardware guidance to narrow the list.',
      detail: 'Queries recommended models based on the detected local hardware profile.',
      group: 'AI',
      keywords: 'recommended models hardware guidance',
      disabled: !state.aiState,
      hint: state.aiState ? 'Enter' : 'Start Core Services',
    },
    {
      id: 'search-skills',
      title: 'Search ClawHub Skills',
      subtitle: 'Browse installable OpenClaw skills from RoachNet.',
      detail: 'Queries the OpenClaw skill catalog using the current search term or a default query.',
      group: 'AI',
      keywords: 'skills clawhub openclaw search install',
      disabled: !state.aiState,
      hint: state.aiState ? 'Enter' : 'Start Core Services',
    },
    {
      id: 'upload-knowledge-files',
      title: 'Add Knowledge Files',
      subtitle: 'Open the native file picker and ingest documents locally.',
      detail: 'Adds files into the RoachNet knowledge workspace for local indexing and RAG.',
      group: 'Knowledge',
      keywords: 'knowledge files upload rag workspace',
      disabled: !desktopState.install?.installed,
      hint: desktopState.install?.installed ? 'Enter' : 'Install first',
    },
    {
      id: 'scan-knowledge-storage',
      title: 'Scan Knowledge Storage',
      subtitle: 'Rescan the local knowledge workspace and active sources.',
      detail: 'Refreshes the indexed source view from the local knowledge storage path.',
      group: 'Knowledge',
      keywords: 'knowledge scan rescan workspace',
      disabled: !desktopState.install?.installed,
      hint: desktopState.install?.installed ? 'Enter' : 'Install first',
    },
    {
      id: 'refresh-knowledge',
      title: 'Refresh Knowledge State',
      subtitle: 'Reload knowledge files and active embedding jobs.',
      detail: 'Polls the knowledge APIs again without changing any local files.',
      group: 'Knowledge',
      keywords: 'knowledge refresh jobs files',
      disabled: !desktopState.install?.installed,
      hint: desktopState.install?.installed ? 'Enter' : 'Install first',
    },
    {
      id: 'open-mlx-docs',
      title: 'Open MLX Docs',
      subtitle: 'Jump to Apple Silicon acceleration references.',
      detail: 'Opens the MLX documentation in the default browser.',
      group: 'Acceleration',
      keywords: 'mlx docs apple silicon',
      hint: 'Enter',
    },
    {
      id: 'open-exo-docs',
      title: 'Open exo Repo',
      subtitle: 'Review the distributed local inference project.',
      detail: 'Opens the exo repository reference in the default browser.',
      group: 'Acceleration',
      keywords: 'exo repo distributed cluster inference',
      hint: 'Enter',
    },
  ]

  for (const model of installedModels.slice(0, 8)) {
    commands.push({
      id: `select-chat-model:${model.name}`,
      title: `Use ${model.name} For Chat`,
      subtitle: selectedModel === model.name ? 'Current active chat model.' : 'Switch the active workbench model immediately.',
      detail: 'Changes the current local chat model without modifying installed models on disk.',
      group: 'Models',
      keywords: `model chat ${model.name}`,
      hint: selectedModel === model.name ? 'Active' : 'Enter',
    })
  }

  for (const session of chatSessions.slice(0, 8)) {
    const label = session.title || session.summary || `Session ${session.id}`
    commands.push({
      id: `open-chat-session:${session.id}`,
      title: `Open ${label}`,
      subtitle: session.model ? `Continue with ${session.model}.` : 'Return to an earlier session.',
      detail: 'Loads the selected session into the native AI workbench.',
      group: 'Sessions',
      keywords: `chat session ${label} ${session.model || ''}`,
      hint: 'Enter',
    })
  }

  return commands
}

function getFilteredRoachCastCommands() {
  const query = state.roachCastQuery.trim().toLowerCase()
  const commands = getRoachCastCommands()

  if (!query) {
    return commands
  }

  return commands.filter((command) => {
    const haystack = [
      command.title,
      command.subtitle,
      command.detail,
      command.group,
      command.keywords,
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase()

    return haystack.includes(query)
  })
}

function getSelectedRoachCastCommand() {
  const commands = getFilteredRoachCastCommands()
  if (!commands.length) {
    return null
  }

  return commands[clamp(state.roachCastSelectedIndex, 0, commands.length - 1)]
}

async function runRoachCastCommand(commandId) {
  const command = getRoachCastCommands().find((item) => item.id === commandId)
  if (!command || command.disabled) {
    return
  }

  const config = updateDraftFromForm()
  const aiDraft = updateAiDraftFromForm()
  closeRoachCast()

  if (commandId.startsWith('select-chat-model:')) {
    const model = commandId.split(':').slice(1).join(':')
    state.aiDraft = {
      ...aiDraft,
      model,
      chatModel: model,
    }
    render()
    return
  }

  if (commandId.startsWith('open-chat-session:')) {
    const sessionId = Number(commandId.split(':').pop())
    await withBusy('open-chat-session', async () => {
      await loadActiveSession(sessionId)
    })
    return
  }

  await withBusy(`roachcast:${commandId}`, async () => {
    switch (commandId) {
      case 'start-app':
        await desktop.startMode('app')
        break
      case 'stop-runtime':
        await desktop.stopRuntime()
        state.aiState = null
        state.knowledgeState = null
        state.activeSessionId = null
        state.activeSession = null
        break
      case 'open-installer-helper':
        await desktop.openInstallerHelper()
        break
      case 'check-updates':
        await desktop.checkForUpdates()
        break
      case 'open-install-folder':
        await desktop.openInstallFolder()
        break
      case 'open-releases':
        await desktop.openReleaseDownloads()
        break
      case 'start-container-runtime':
        await desktop.startContainerRuntime()
        break
      case 'refresh-ai':
        await refreshAIState({ force: true })
        break
      case 'apply-roachclaw':
        await desktop.applyRoachClaw({
          model: aiDraft.model || getSelectedChatModel(),
          workspacePath: aiDraft.workspacePath,
          ollamaBaseUrl: aiDraft.ollamaBaseUrl,
          openclawBaseUrl: aiDraft.openclawBaseUrl,
        })
        break
      case 'search-models':
        state.modelSearchResults = await desktop.searchModels({
          query: state.modelSearchQuery || 'qwen',
          recommendedOnly: false,
          limit: 12,
          sort: 'pulls',
        })
        break
      case 'search-models-recommended':
        state.modelSearchResults = await desktop.searchModels({
          query: state.modelSearchQuery,
          recommendedOnly: true,
          limit: 12,
          sort: 'pulls',
        })
        break
      case 'search-skills':
        state.skillSearchResults = await desktop.searchSkills({
          query: state.skillSearchQuery || 'calendar',
          limit: 8,
        })
        break
      case 'upload-knowledge-files':
        await desktop.selectAndUploadKnowledgeFiles()
        break
      case 'scan-knowledge-storage':
        await desktop.scanKnowledgeStorage()
        break
      case 'refresh-knowledge':
        await refreshKnowledgeState({ force: true })
        break
      case 'open-mlx-docs':
        await desktop.openMlxDocs()
        break
      case 'open-exo-docs':
        await desktop.openExoDocs()
        break
      default:
        break
    }
  })
}

function syncDraftConfig(force = false) {
  const incoming = state.desktopState?.setup?.config || state.desktopState?.config
  if (!incoming) {
    return
  }

  if (!state.draftConfig || force) {
    state.draftConfig = { ...incoming }
  }
}

function syncAiDraft(force = false) {
  const roachClaw = getRoachClawStatus()
  if (!roachClaw) {
    return
  }

  const installedModels = getInstalledModels()
  const firstInstalledModel = installedModels[0]?.name || ''
  const nextDraft = {
    model: roachClaw.defaultModel || firstInstalledModel,
    chatModel:
      state.activeSession?.model || roachClaw.defaultModel || firstInstalledModel,
    workspacePath: roachClaw.workspacePath || '',
    ollamaBaseUrl: roachClaw.ollama?.baseUrl || '',
    openclawBaseUrl: roachClaw.openclaw?.baseUrl || '',
  }

  if (!state.aiDraft || force) {
    state.aiDraft = nextDraft
    return
  }

  state.aiDraft = {
    ...nextDraft,
    ...state.aiDraft,
  }
}

function renderTaskPanel(task, fallbackTitle) {
  if (!task) {
    return `
      <article class="log-card">
        <h3 class="section-title">${escapeHtml(fallbackTitle)}</h3>
        <div class="empty-note">No setup activity has been recorded in this session yet.</div>
      </article>
    `
  }

  const lines = Array.isArray(task.logs) ? task.logs.slice(-18) : []

  return `
    <article class="task-card">
      <div class="metric-header">
        <h3 class="section-title">${escapeHtml(fallbackTitle)}</h3>
        ${statusPill(task.status || 'idle')}
      </div>
      <div class="task-meta">
        Started: ${escapeHtml(formatDate(task.startedAt))}
        ${task.finishedAt ? ` | Finished: ${escapeHtml(formatDate(task.finishedAt))}` : ''}
      </div>
      <div class="log-scroll">
        ${
          lines.length
            ? lines.map((line) => `<div class="log-line">${escapeHtml(line)}</div>`).join('')
            : '<div class="empty-note">This task has no log output yet.</div>'
        }
      </div>
    </article>
  `
}

function renderIntroOverlay() {
  if (!state.introVisible) {
    return ''
  }

  const step = ROACHNET_TOUR_STEPS[state.introStepIndex] || ROACHNET_TOUR_STEPS[0]
  const sceneCards = [
    {
      label: 'Install',
      value: 'Contained layout',
      detail: 'App, runtime, and managed content grouped together.',
      active: step.id === 'contained',
    },
    {
      label: 'RoachClaw',
      value: 'Local AI default',
      detail: 'OpenClaw routed through a local Ollama model.',
      active: step.id === 'roachclaw',
    },
    {
      label: 'Workspace',
      value: 'Native command center',
      detail: 'A calmer shell for setup, runtime, and local tools.',
      active: step.id === 'workspace',
    },
    {
      label: 'RoachCast',
      value: 'Quick launch',
      detail: 'Fast action switching inside the suite.',
      active: step.id === 'launch',
    },
  ]

  return `
    <div class="intro-overlay" data-intro-overlay>
      <div class="intro-shell">
        <div class="intro-top">
          <div class="intro-progress">
            ${ROACHNET_TOUR_STEPS.map((tourStep, index) => {
              const active = index === state.introStepIndex
              const complete = index < state.introStepIndex
              return `
                <div class="intro-progress__step${active ? ' intro-progress__step--active' : ''}${complete ? ' intro-progress__step--complete' : ''}">
                  <span>${escapeHtml(tourStep.kicker)}</span>
                </div>
              `
            }).join('')}
          </div>
          <button class="rn-button ghost small" data-action="dismiss-intro">Skip Tour</button>
        </div>
        <div class="intro-body">
          <div class="intro-scene">
            <div class="intro-mark-wrap">
              <div class="intro-mark-ring intro-mark-ring--outer"></div>
              <div class="intro-mark-ring intro-mark-ring--inner"></div>
              <img class="intro-mark" src="../assets/icon.png" alt="RoachNet" />
            </div>
            <div class="intro-scene__grid">
              ${sceneCards
                .map(
                  (card) => `
                    <article class="intro-scene__card${card.active ? ' intro-scene__card--active' : ''}">
                      <span>${escapeHtml(card.label)}</span>
                      <strong>${escapeHtml(card.value)}</strong>
                      <small>${escapeHtml(card.detail)}</small>
                    </article>
                  `
                )
                .join('')}
            </div>
          </div>
          <div class="intro-copy">
            <div class="intro-kicker">${escapeHtml(step.kicker)}</div>
            <h2>${escapeHtml(step.title)}</h2>
            <p>${escapeHtml(step.body)}</p>
            <div class="intro-meta">
              <span class="shortcut-pill">First launch</span>
              <span class="shortcut-pill">RoachNet native shell</span>
              <span class="shortcut-pill">RoachClaw included</span>
            </div>
            <div class="intro-actions">
              <button class="rn-button primary" data-action="dismiss-intro">Open RoachNet</button>
            </div>
          </div>
        </div>
      </div>
    </div>
  `
}

function renderToggle(name, label, checked, scope = 'config') {
  return `
    <label class="toggle">
      <input type="checkbox" data-${scope}-field name="${escapeHtml(name)}" ${checked ? 'checked' : ''} />
      <span class="toggle-label">
        <strong>${escapeHtml(label)}</strong>
        <span>${checked ? 'Enabled' : 'Disabled'}</span>
      </span>
    </label>
  `
}

function renderMetricCards(desktopState) {
  const runtime = desktopState.runtime || {}
  const updater = desktopState.updater || {}
  const install = desktopState.install || {}
  const runtimeStatus = getRuntimeStatus(runtime)

  const cards = [
    {
      title: 'Shell Mode',
      value: 'Native Renderer',
      detail: `${desktopState.shell.platform} / ${desktopState.shell.arch}`,
    },
    {
      title: 'Runtime Core',
      value: runtime.mode === 'app' ? 'Command Deck' : runtime.mode === 'setup' ? 'Setup Core' : 'Idle',
      detail: runtime.url || 'No RoachNet services started.',
      pill: statusPill(runtimeStatus.label, runtimeStatus.tone),
    },
    {
      title: 'Update Channel',
      value: (updater.releaseChannel || 'stable').toUpperCase(),
      detail: updater.state ? `Updater state: ${updater.state}` : 'Updater idle',
      pill: statusPill(updater.state || 'idle'),
    },
    {
      title: 'Install Target',
      value: install.installed ? 'Ready' : 'Pending',
      detail: install.repoRoot || desktopState.config.installPath || 'No install path chosen.',
      pill: statusPill(install.installed ? 'ready' : 'warning'),
    },
  ]

  return cards
    .map(
      (card) => `
        <article class="metric-card">
          <div class="metric-header">
            <h3>${escapeHtml(card.title)}</h3>
            ${card.pill || ''}
          </div>
          <div class="metric-value">${escapeHtml(card.value)}</div>
          <div class="metric-detail">${escapeHtml(card.detail)}</div>
        </article>
      `
    )
    .join('')
}

function renderModules(desktopState) {
  const install = desktopState.install || {}
  const runtime = desktopState.runtime || {}

  const modules = [
    {
      title: 'RoachClaw',
      summary: 'Combined Ollama + OpenClaw onboarding now has a native control surface with local model defaults and skill installs.',
      status: install.installed ? 'native live' : 'setup first',
    },
    {
      title: 'AI Runtime',
      summary: 'The shell can auto-start the local RoachNet core, probe providers, and manage model downloads from native controls.',
      status: runtime.mode === 'app' ? 'live' : 'standby',
    },
    {
      title: 'Optimization',
      summary: 'Hardware profile guidance is surfaced natively so Apple Silicon, ARM64, and x86 systems can steer toward sane local-model defaults.',
      status: 'advisory',
    },
    {
      title: 'Chat Workbench',
      summary: 'The built-in workbench handles local chat, coding, and prompt tasks through the RoachClaw path.',
      status: install.installed ? 'ready' : 'pending',
    },
    {
      title: 'RoachCast',
      summary: 'A fast command launcher for RoachNet actions, sessions, models, and utility shortcuts.',
      status: 'tool',
    },
  ]

  return modules
    .map(
      (module) => `
        <article class="module-card">
          <div class="metric-header">
            <h3>${escapeHtml(module.title)}</h3>
            ${statusPill(module.status)}
          </div>
          <p>${escapeHtml(module.summary)}</p>
        </article>
      `
    )
    .join('')
}

function renderSetupPanel(desktopState) {
  const setupState = desktopState.setup
  const config = getEffectiveConfig()
  const containerRuntime = setupState?.containerRuntime || null
  const sourceModes = setupState?.sourceModes || [
    {
      id: 'clone',
      label: 'Clone from GitHub',
      description: 'Download RoachNet into the chosen install folder from the configured git repository.',
    },
    {
      id: 'bundled',
      label: 'Install bundled RoachNet',
      description: 'Copy the bundled RoachNet payload into the selected folder.',
    },
    {
      id: 'current-workspace',
      label: 'Use current workspace',
      description: 'Advanced option: install from the active local source tree.',
    },
  ]
  const selectedSourceMode = sourceModes.find((mode) => mode.id === config.sourceMode)

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>Installer</h2>
          <p>Set the install location, release channel, and RoachClaw defaults.</p>
        </div>
        ${statusPill(setupState?.activeTask ? 'running' : desktopState.install?.installed ? 'ready' : 'standby')}
      </div>
      <div class="panel-body">
        <div class="field-grid">
          <label class="field wide">
            <span class="field-label">Install Path</span>
            <input data-config-field name="installPath" value="${escapeHtml(config.installPath || '')}" placeholder="~/RoachNet" />
          </label>
          <label class="field wide">
            <span class="field-label">Desktop App Path</span>
            <input data-config-field name="installedAppPath" value="${escapeHtml(config.installedAppPath || '')}" placeholder="~/RoachNet/app/RoachNet.app" />
          </label>
          <label class="field">
            <span class="field-label">Source Mode</span>
            <select data-config-field name="sourceMode">
              ${sourceModes
                .map((mode) => {
                  const disabled = mode.available === false ? ' disabled' : ''
                  const selected = config.sourceMode === mode.id ? ' selected' : ''
                  return `<option value="${escapeHtml(mode.id)}"${selected}${disabled}>${escapeHtml(mode.label)}</option>`
                })
                .join('')}
            </select>
            <span class="field-help">${
              selectedSourceMode?.description
                ? escapeHtml(selectedSourceMode.description)
                : 'Select where RoachNet should come from.'
            }</span>
          </label>
          <label class="field">
            <span class="field-label">Release Channel</span>
            <select data-config-field name="releaseChannel">
              ${['stable', 'beta', 'alpha']
                .map(
                  (channel) =>
                    `<option value="${channel}"${config.releaseChannel === channel ? ' selected' : ''}>${channel.toUpperCase()}</option>`
                )
                .join('')}
            </select>
          </label>
          <label class="field">
            <span class="field-label">RoachClaw Default Model</span>
            <input data-config-field name="roachClawDefaultModel" value="${escapeHtml(config.roachClawDefaultModel || 'qwen2.5-coder:7b')}" placeholder="qwen2.5-coder:7b" />
            <span class="field-help">This local Ollama model becomes the default model path for RoachClaw.</span>
          </label>
          <label class="field wide">
            <span class="field-label">Source Repository</span>
            <input data-config-field name="sourceRepoUrl" value="${escapeHtml(config.sourceRepoUrl || '')}" placeholder="https://github.com/AHGRoach/RoachNet.git" />
          </label>
          <label class="field">
            <span class="field-label">Source Ref</span>
            <input data-config-field name="sourceRef" value="${escapeHtml(config.sourceRef || '')}" placeholder="main" />
          </label>
          <label class="field">
            <span class="field-label">Update Feed Override</span>
            <input data-config-field name="updateBaseUrl" value="${escapeHtml(config.updateBaseUrl || '')}" placeholder="Optional generic update URL" />
          </label>
        </div>

        <div class="toggle-grid" style="margin-top: 16px;">
          ${renderToggle('autoInstallDependencies', 'Auto-install dependencies', config.autoInstallDependencies)}
          ${renderToggle('installRoachClaw', 'Install RoachClaw during setup', config.installRoachClaw !== false)}
          ${renderToggle('autoLaunch', 'Auto-launch after install', config.autoLaunch)}
          ${renderToggle('autoCheckUpdates', 'Auto-check release updates', config.autoCheckUpdates)}
          ${renderToggle('launchAtLogin', 'Launch RoachNet at login', config.launchAtLogin)}
          ${renderToggle('dryRun', 'Preview setup only', config.dryRun)}
        </div>

        ${
          containerRuntime
            ? `
              <div class="log-card" style="margin-top: 18px;">
                <div class="metric-header">
                  <h3 class="section-title">RoachNet Container Runtime</h3>
                  ${statusPill(containerRuntime.ready ? 'ready' : containerRuntime.dockerCliPath ? 'warning' : 'missing')}
                </div>
                <div class="metric-detail">
                  Docker CLI: ${escapeHtml(containerRuntime.dockerCliPath || 'Not detected')}<br />
                  Compose: ${escapeHtml(containerRuntime.composeAvailable ? 'Docker Compose v2 ready' : 'Not available')}<br />
                  Daemon: ${escapeHtml(containerRuntime.daemonRunning ? 'Running' : 'Stopped')}<br />
                  Desktop: ${
                    containerRuntime.desktopCapable
                      ? escapeHtml(
                          containerRuntime.desktopCliAvailable
                            ? containerRuntime.desktopStatus
                            : 'Desktop CLI unavailable'
                        )
                      : 'Linux host service mode'
                  }<br />
                  Project: ${escapeHtml(containerRuntime.composeProjectName)}
                </div>
                <div class="metric-detail" style="margin-top: 12px;">
                  RoachClaw: ${escapeHtml(config.installRoachClaw !== false ? `enabled · default model ${config.roachClawDefaultModel || 'qwen2.5-coder:7b'}` : 'disabled')}
                </div>
                <div class="metric-detail" style="margin-top: 12px;">
                  Install layout: ${escapeHtml('App, runtime, storage, and managed content stay grouped inside the RoachNet install folder whenever possible.')}
                </div>
                <div class="action-row" style="margin-top: 14px;">
                  <button class="rn-button secondary" data-action="start-container-runtime" ${containerRuntime.ready ? 'disabled' : ''}>Start Container Runtime</button>
                </div>
              </div>
            `
            : ''
        }

        <div class="action-row" style="margin-top: 18px;">
          <button class="rn-button primary" data-action="save-config">Save Setup Profile</button>
          <button class="rn-button secondary" data-action="open-installer-helper">Open RoachNet Setup</button>
          <button class="rn-button ghost" data-action="start-app" ${desktopState.install?.installed ? '' : 'disabled'}>Start Command Deck</button>
        </div>

        ${
          !setupState
            ? `
              <div class="banner" style="margin-top: 18px;">
                <div>
                  <strong>Ready to configure</strong>
                  <div>Starting setup will bring the required services online automatically.</div>
                </div>
              </div>
            `
            : ''
        }

        <div style="margin-top: 18px;">
          ${renderTaskPanel(setupState?.activeTask, 'Active Setup Task')}
        </div>
      </div>
    </section>
  `
}

function renderDashboard(desktopState) {
  const runtime = desktopState.runtime || {}
  const setup = desktopState.setup || {}

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>Overview</h2>
          <p>Quick controls for runtime, updates, setup, and the RoachNet suite.</p>
        </div>
        ${statusPill(runtime.mode || 'idle')}
      </div>
      <div class="panel-body">
        <div class="metrics-grid">
          ${renderMetricCards(desktopState)}
        </div>

        <div class="action-row" style="margin-top: 18px;">
          <button class="rn-button primary" data-action="start-app" ${desktopState.install?.installed ? '' : 'disabled'}>Start Core Services</button>
          <button class="rn-button secondary" data-action="open-installer-helper">Open RoachNet Setup</button>
          <button class="rn-button secondary" data-action="toggle-roachcast">Open RoachCast</button>
          <button class="rn-button ghost" data-action="stop-runtime" ${runtime.running ? '' : 'disabled'}>Stop Services</button>
          <button class="rn-button ghost" data-action="check-updates">Check Updates</button>
          <button class="rn-button ghost" data-action="open-install-folder" ${desktopState.install?.installed ? '' : 'disabled'}>Open Install Folder</button>
          <button class="rn-button ghost" data-action="open-releases">Release Downloads</button>
        </div>

        ${
          runtime.lastError
            ? `
              <div class="banner error" style="margin-top: 18px;">
                <div>
                  <strong>Runtime Warning</strong>
                  <div>${escapeHtml(runtime.lastError)}</div>
                </div>
              </div>
            `
            : ''
        }

        <div style="margin-top: 18px;" class="module-grid">
          ${renderModules(desktopState)}
        </div>

        <div style="margin-top: 18px;">
          ${renderTaskPanel(setup.lastCompletedTask, 'Recent Setup Activity')}
        </div>
      </div>
    </section>
  `
}

function renderCommandDeckHero(desktopState) {
  const runtime = desktopState.runtime || {}
  const updater = desktopState.updater || {}
  const install = desktopState.install || {}
  const config = getEffectiveConfig()
  const runtimeStatus = getRuntimeStatus(runtime)
  const routeLabel = getPreferredChatRouteLabel()

  return `
    <section class="hero-strip hero-strip--minimal">
      <article class="hero-strip__lead">
        <div class="hero-kicker">Command Deck</div>
        <h2>Local-first tools, one native workspace.</h2>
        <p>RoachNet keeps setup, runtime, RoachClaw, models, chat, and knowledge work aligned in one shell.</p>
        <div class="hero-strip__actions">
          <button class="rn-button primary" data-action="start-app" ${install.installed ? '' : 'disabled'}>Open Workbench</button>
          <button class="rn-button secondary" data-action="open-installer-helper">Open RoachNet Setup</button>
          <button class="rn-button ghost" data-action="toggle-roachcast">RoachCast</button>
        </div>
      </article>
      <div class="hero-strip__grid">
        <article class="hero-stat">
          <span>Native Runtime</span>
          <strong>${escapeHtml(runtimeStatus.label)}</strong>
          <small>${escapeHtml(runtime.url || 'No RoachNet services are live yet.')}</small>
        </article>
        <article class="hero-stat">
          <span>RoachClaw</span>
          <strong>${escapeHtml(config.installRoachClaw !== false ? config.roachClawDefaultModel || 'qwen2.5-coder:7b' : 'Disabled')}</strong>
          <small>Local Ollama models remain the default model path for OpenClaw.</small>
        </article>
        <article class="hero-stat">
          <span>Install Root</span>
          <strong>${escapeHtml(install.repoRoot || config.installPath || 'Not installed')}</strong>
          <small>Contained by default.</small>
        </article>
        <article class="hero-stat">
          <span>Updates</span>
          <strong>${escapeHtml((updater.releaseChannel || 'stable').toUpperCase())}</strong>
          <small>${escapeHtml(updater.state ? `Updater ${updater.state}` : 'Update checks are ready when you need them.')}</small>
        </article>
        <article class="hero-stat">
          <span>AI Route</span>
          <strong>${escapeHtml(routeLabel)}</strong>
          <small>Single-machine mode stays local first.</small>
        </article>
        <article class="hero-stat">
          <span>Shell Mode</span>
          <strong>Native Desktop</strong>
          <small>Suite controls live in the desktop shell.</small>
        </article>
      </div>
    </section>
  `
}

function renderCommandDeckRibbon(desktopState) {
  const runtime = desktopState.runtime || {}
  const install = desktopState.install || {}
  const config = getEffectiveConfig()
  const roachClaw = getRoachClawStatus()
  const runtimeStatus = getRuntimeStatus(runtime)
  const selectedModel = getSelectedChatModel()

  return `
    <section class="command-ribbon">
      <article class="command-ribbon__lead">
        <div class="hero-kicker">Suite Overview</div>
        <h3>Contained install. Local AI. Fast control.</h3>
        <p>The suite stays grouped together instead of scattering setup, runtime, and AI controls across separate utilities.</p>
      </article>
      <div class="command-ribbon__grid">
        <article class="command-ribbon__card">
          <span>Runtime</span>
          <strong>${escapeHtml(runtimeStatus.label)}</strong>
          <small>${escapeHtml(runtime.mode ? `Mode: ${runtime.mode}` : 'RoachNet runtime is standing by.')}</small>
        </article>
        <article class="command-ribbon__card">
          <span>RoachClaw</span>
          <strong>${escapeHtml(roachClaw?.defaultModel || config.roachClawDefaultModel || 'qwen2.5-coder:7b')}</strong>
          <small>Local model-first default.</small>
        </article>
        <article class="command-ribbon__card">
          <span>Install Root</span>
          <strong>${escapeHtml(install.repoRoot || config.installPath || 'Not installed')}</strong>
          <small>Managed data stays grouped with the install.</small>
        </article>
        <article class="command-ribbon__card">
          <span>Active Chat Model</span>
          <strong>${escapeHtml(selectedModel || 'Not selected')}</strong>
          <small>Switch models without leaving the shell.</small>
        </article>
      </div>
    </section>
  `
}

function getWorkspacePanes(desktopState) {
  const runtime = desktopState.runtime || {}
  const install = desktopState.install || {}
  const aiReady = Boolean(state.aiState)
  const knowledgeReady = Boolean(state.knowledgeState)

  return [
    {
      id: 'overview',
      label: 'Overview',
      detail: 'Command center and launch controls.',
      status: runtime.running ? 'live' : install.installed ? 'ready' : 'standby',
    },
    {
      id: 'setup',
      label: 'Setup',
      detail: 'Install profile and first-run settings.',
      status: desktopState.setup?.activeTask ? 'running' : install.installed ? 'ready' : 'standby',
    },
    {
      id: 'ai',
      label: 'AI Studio',
      detail: 'Models, RoachClaw, chat, and acceleration.',
      status: aiReady ? 'available' : install.installed ? 'pending' : 'standby',
    },
    {
      id: 'knowledge',
      label: 'Knowledge',
      detail: 'Local files and active jobs.',
      status: knowledgeReady ? 'ready' : install.installed ? 'pending' : 'standby',
    },
  ]
}

function renderSidebarNav(desktopState) {
  const panes = getWorkspacePanes(desktopState)

  return `
    <aside class="panel suite-sidebar">
      <div class="panel-header">
        <div>
          <h2>Workspace</h2>
          <p>Move through the suite without loading everything at once.</p>
        </div>
      </div>
      <div class="panel-body">
        <div class="suite-nav">
          ${panes
            .map(
              (pane) => `
                <button
                  class="suite-nav__item${state.activePane === pane.id ? ' suite-nav__item--active' : ''}"
                  data-action="set-pane"
                  data-pane="${escapeHtml(pane.id)}"
                >
                  <span class="suite-nav__label">${escapeHtml(pane.label)}</span>
                  ${statusPill(pane.status)}
                </button>
              `
            )
            .join('')}
        </div>
        <div class="suite-sidebar__footer">
          <button class="rn-button secondary" data-action="toggle-roachcast">Open RoachCast</button>
          <button class="rn-button ghost" data-action="check-updates">Check Updates</button>
        </div>
      </div>
    </aside>
  `
}

function renderPaneSpotlight(desktopState) {
  const pane = getWorkspacePanes(desktopState).find((entry) => entry.id === state.activePane)
  const config = getEffectiveConfig()
  const install = desktopState.install || {}
  const runtime = desktopState.runtime || {}
  const runtimeStatus = getRuntimeStatus(runtime)

  if (!pane) {
    return ''
  }

  return `
    <section class="pane-spotlight">
      <article class="pane-spotlight__lead">
        <div class="hero-kicker">${escapeHtml(pane.label)}</div>
        <h2>${escapeHtml(
          pane.id === 'overview'
            ? 'A calmer native control surface for the suite.'
            : pane.id === 'setup'
              ? 'Set installation and first-run behavior without leaving the app.'
              : pane.id === 'ai'
                ? 'Manage local AI, RoachClaw, models, and acceleration in one place.'
                : 'Manage local knowledge without scattering files across the machine.'
        )}</h2>
        <p>${escapeHtml(pane.detail)}</p>
      </article>
      <div class="pane-spotlight__stats">
        <article class="pane-spotlight__card">
          <span>Install Root</span>
          <strong>${escapeHtml(install.repoRoot || config.installPath || 'Not installed')}</strong>
          <small>Contained by default.</small>
        </article>
        <article class="pane-spotlight__card">
          <span>Runtime</span>
          <strong>${escapeHtml(runtimeStatus.label)}</strong>
          <small>${escapeHtml(runtime.mode ? `Mode: ${runtime.mode}` : 'RoachNet services are standing by.')}</small>
        </article>
        <article class="pane-spotlight__card">
          <span>RoachClaw</span>
          <strong>${escapeHtml(config.roachClawDefaultModel || 'qwen2.5-coder:7b')}</strong>
          <small>Local Ollama remains the default path.</small>
        </article>
      </div>
    </section>
  `
}

function renderActivePane(desktopState) {
  switch (state.activePane) {
    case 'setup':
      return renderSetupPanel(desktopState)
    case 'ai':
      return `
        <div class="content-stack">
          ${renderAIStudio(desktopState)}
          ${renderAccelerationStudio(desktopState)}
        </div>
      `
    case 'knowledge':
      return (
        renderKnowledgeStudio(desktopState) ||
        `
          <section class="panel">
            <div class="panel-header">
              <div>
                <h2>Knowledge</h2>
                <p>Install RoachNet first to enable local document ingestion and knowledge workspaces.</p>
              </div>
              ${statusPill('pending')}
            </div>
            <div class="panel-body">
              <div class="empty-note">Knowledge tools appear here once the native install is complete.</div>
            </div>
          </section>
        `
      )
    case 'overview':
    default:
      return `
        <div class="content-stack">
          ${renderCommandDeckHero(desktopState)}
          ${renderDashboard(desktopState)}
        </div>
      `
  }
}

function renderRoachCast() {
  if (!state.roachCastOpen) {
    return ''
  }

  const commands = getFilteredRoachCastCommands()
  const selectedIndex = clamp(state.roachCastSelectedIndex, 0, Math.max(commands.length - 1, 0))
  const selectedCommand = commands[selectedIndex] || null

  return `
    <div class="roachcast-overlay" data-action="close-roachcast-overlay">
      <div class="roachcast-shell" role="dialog" aria-modal="true" aria-label="RoachCast">
        <div class="roachcast-header">
          <div>
            <div class="hero-kicker">RoachCast</div>
            <h2>Quick launcher for the RoachNet suite</h2>
            <p>Search commands, jump between tools, and move through RoachNet faster.</p>
          </div>
          <div class="roachcast-shortcut-row">
            <span class="shortcut-pill">${navigator.platform.toLowerCase().includes('mac') ? 'Cmd' : 'Ctrl'} K</span>
            <button class="rn-button ghost small" data-action="close-roachcast">Close</button>
          </div>
        </div>

        <label class="roachcast-search">
          <span class="roachcast-search__icon">⌘</span>
          <input
            class="roachcast-search__input"
            data-ui-field="roachCastQuery"
            value="${escapeHtml(state.roachCastQuery)}"
            placeholder="Search actions, models, sessions, docs, and local tools..."
            autocomplete="off"
          />
        </label>

        <div class="roachcast-body">
          <div class="roachcast-list">
            ${
              commands.length
                ? commands
                    .map(
                      (command, index) => `
                        <button
                          class="roachcast-item${index === selectedIndex ? ' roachcast-item--active' : ''}"
                          data-action="run-roachcast-command"
                          data-command-id="${escapeHtml(command.id)}"
                          ${command.disabled ? 'disabled' : ''}
                        >
                          <span class="roachcast-item__meta">
                            <span class="roachcast-item__group">${escapeHtml(command.group)}</span>
                            <strong>${escapeHtml(command.title)}</strong>
                            <span>${escapeHtml(command.subtitle)}</span>
                          </span>
                          <span class="roachcast-item__hint">${escapeHtml(command.hint || 'Enter')}</span>
                        </button>
                      `
                    )
                    .join('')
                : '<div class="empty-note">No commands match this search yet.</div>'
            }
          </div>

          <aside class="roachcast-preview">
            ${
              selectedCommand
                ? `
                  <div class="roachcast-preview__group">${escapeHtml(selectedCommand.group)}</div>
                  <h3>${escapeHtml(selectedCommand.title)}</h3>
                  <p>${escapeHtml(selectedCommand.detail || selectedCommand.subtitle)}</p>
                  <div class="roachcast-preview__footer">
                    <span class="shortcut-pill">Enter</span>
                    <span class="shortcut-pill">↑ ↓</span>
                    <span class="shortcut-pill">Esc</span>
                  </div>
                `
                : `
                  <div class="empty-note">Search the suite to jump straight into a native RoachNet action.</div>
                `
            }
          </aside>
        </div>
      </div>
    </div>
  `
}

function renderAiMetrics() {
  const systemInfo = getSystemInfo()
  const roachClaw = getRoachClawStatus()
  const providers = getProviderStatus().providers || {}
  const hardware = systemInfo?.hardwareProfile || null

  const cards = [
    {
      title: 'Hardware Profile',
      value: hardware?.platformLabel || 'Unknown',
      detail: hardware
        ? `${hardware.chipFamily} | ${hardware.memoryTier} | ${hardware.recommendedModelClass}`
        : 'Start the core services to read the hardware profile.',
    },
    {
      title: 'Ollama Runtime',
      value: providers.ollama?.available ? 'Ready' : 'Offline',
      detail: providers.ollama?.baseUrl || providers.ollama?.error || 'No Ollama endpoint detected.',
      pill: statusPill(providers.ollama?.available ? 'available' : 'offline'),
    },
    {
      title: 'OpenClaw Runtime',
      value: providers.openclaw?.available ? 'Ready' : 'Offline',
      detail: providers.openclaw?.baseUrl || providers.openclaw?.error || 'No OpenClaw endpoint detected.',
      pill: statusPill(providers.openclaw?.available ? 'available' : 'offline'),
    },
    {
      title: 'RoachClaw Default',
      value: roachClaw?.defaultModel || 'Not Set',
      detail: roachClaw?.workspacePath || 'No OpenClaw workspace configured yet.',
      pill: statusPill(roachClaw?.defaultModel ? 'applied' : 'pending'),
    },
  ]

  return cards
    .map(
      (card) => `
        <article class="metric-card">
          <div class="metric-header">
            <h3>${escapeHtml(card.title)}</h3>
            ${card.pill || ''}
          </div>
          <div class="metric-value">${escapeHtml(card.value)}</div>
          <div class="metric-detail">${escapeHtml(card.detail)}</div>
        </article>
      `
    )
    .join('')
}

function renderAiHints() {
  const systemInfo = getSystemInfo()
  const hardware = systemInfo?.hardwareProfile

  if (!hardware) {
    return '<div class="empty-note">Hardware-specific tuning guidance will appear once the app core is running.</div>'
  }

  const hints = [...(hardware.notes || []), ...(hardware.warnings || [])]
  return hints
    .map((note) => `<div class="log-line">${escapeHtml(note)}</div>`)
    .join('')
}

function renderModelLibrary() {
  const models = getInstalledModels()
  const searchResults = state.modelSearchResults?.models || []
  const chatModel = getSelectedChatModel()

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>Local Model Library</h2>
          <p>Use RoachNet as the LMStudio-style control plane for local Ollama models.</p>
        </div>
        ${statusPill(models.length ? 'ready' : 'pending')}
      </div>
      <div class="panel-body ai-subgrid">
        <article class="log-card">
          <h3 class="section-title">Installed Models</h3>
          <div class="list-stack">
            ${
              models.length
                ? models
                    .map(
                      (model) => `
                        <div class="list-item">
                          <div>
                            <strong>${escapeHtml(model.name)}</strong>
                            <div class="metric-detail">${escapeHtml(model.details?.parameter_size || model.model || 'Local Ollama model')}</div>
                          </div>
                          <div class="inline-actions">
                            ${chatModel === model.name ? statusPill('chat default') : ''}
                            <button class="rn-button ghost small" data-action="delete-model" data-model="${escapeHtml(model.name)}">Delete</button>
                          </div>
                        </div>
                      `
                    )
                    .join('')
                : '<div class="empty-note">No local models are installed yet.</div>'
            }
          </div>
        </article>

        <article class="log-card">
          <h3 class="section-title">Catalog Search</h3>
          <div class="field-grid single-column">
            <label class="field wide">
              <span class="field-label">Search Ollama Library</span>
              <input data-ui-field="modelSearchQuery" value="${escapeHtml(state.modelSearchQuery)}" placeholder="llama, qwen, coder, embed..." />
            </label>
          </div>
          <div class="action-row" style="margin-top: 12px;">
            <button class="rn-button secondary" data-action="search-models">Search Models</button>
            <button class="rn-button ghost" data-action="search-models-recommended">Recommended</button>
          </div>
          <div class="list-stack" style="margin-top: 14px;">
            ${
              searchResults.length
                ? searchResults
                    .map(
                      (model) => `
                        <div class="list-item">
                          <div>
                            <strong>${escapeHtml(model.name)}</strong>
                            <div class="metric-detail">${escapeHtml(model.description || model.model || 'Available model')}</div>
                          </div>
                          <div class="inline-actions">
                            <button class="rn-button small" data-action="install-model" data-model="${escapeHtml(model.name)}">Install</button>
                          </div>
                        </div>
                      `
                    )
                    .join('')
                : '<div class="empty-note">Search the Ollama library to queue a download.</div>'
            }
          </div>
        </article>
      </div>
    </section>
  `
}

function renderSkillLibrary() {
  const skillCliStatus = getSettledData(state.aiState?.skillCliStatus, null)
  const installedSkills = getInstalledSkills()
  const searchResults = state.skillSearchResults?.skills || []

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>OpenClaw Skill Library</h2>
          <p>Browse and install ClawHub skills so OpenClaw works out of the box with your local RoachClaw runtime.</p>
        </div>
        ${statusPill(skillCliStatus?.openclawAvailable ? 'available' : 'pending')}
      </div>
      <div class="panel-body ai-subgrid">
        <article class="log-card">
          <h3 class="section-title">Installed Skills</h3>
          <div class="metric-detail">Workspace: ${escapeHtml(skillCliStatus?.workspacePath || 'Not configured')}</div>
          <div class="list-stack" style="margin-top: 12px;">
            ${
              installedSkills.length
                ? installedSkills
                    .map(
                      (skill) => `
                        <div class="list-item">
                          <div>
                            <strong>${escapeHtml(skill.name || skill.slug)}</strong>
                            <div class="metric-detail">${escapeHtml(skill.description || skill.path || 'Installed OpenClaw skill')}</div>
                          </div>
                          ${statusPill('installed')}
                        </div>
                      `
                    )
                    .join('')
                : '<div class="empty-note">No OpenClaw skills are installed in the active workspace yet.</div>'
            }
          </div>
        </article>

        <article class="log-card">
          <h3 class="section-title">ClawHub Search</h3>
          <div class="field-grid single-column">
            <label class="field wide">
              <span class="field-label">Search ClawHub</span>
              <input data-ui-field="skillSearchQuery" value="${escapeHtml(state.skillSearchQuery)}" placeholder="calendar, coding, filesystem..." />
            </label>
          </div>
          <div class="action-row" style="margin-top: 12px;">
            <button class="rn-button secondary" data-action="search-skills">Search Skills</button>
          </div>
          <div class="list-stack" style="margin-top: 14px;">
            ${
              searchResults.length
                ? searchResults
                    .map(
                      (skill) => `
                        <div class="list-item">
                          <div>
                            <strong>${escapeHtml(skill.title || skill.slug)}</strong>
                            <div class="metric-detail">${escapeHtml(skill.slug)}${skill.score !== null ? ` | score ${escapeHtml(skill.score)}` : ''}</div>
                          </div>
                          <div class="inline-actions">
                            <button class="rn-button small" data-action="install-skill" data-skill="${escapeHtml(skill.slug)}">Install</button>
                          </div>
                        </div>
                      `
                    )
                    .join('')
                : '<div class="empty-note">Search ClawHub to add skills to the current OpenClaw workspace.</div>'
            }
          </div>
        </article>
      </div>
    </section>
  `
}

function renderRoachClawStudio() {
  const roachClaw = getRoachClawStatus()
  const aiDraft = getEffectiveAiDraft()
  const installedModels = getInstalledModels()

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>RoachClaw Studio</h2>
          <p>Bind OpenClaw to a local Ollama model, save the workspace defaults, and align the runtime to this machine.</p>
        </div>
        ${statusPill(roachClaw?.defaultModel ? 'applied' : 'pending')}
      </div>
      <div class="panel-body">
        <div class="metrics-grid">
          ${renderAiMetrics()}
        </div>

        <div class="field-grid" style="margin-top: 18px;">
          <label class="field">
            <span class="field-label">Default Local Model</span>
            <select data-ai-field name="model">
              ${installedModels
                .map(
                  (model) =>
                    `<option value="${escapeHtml(model.name)}"${aiDraft.model === model.name ? ' selected' : ''}>${escapeHtml(model.name)}</option>`
                )
                .join('')}
            </select>
          </label>
          <label class="field">
            <span class="field-label">Chat Workbench Model</span>
            <select data-ai-field name="chatModel">
              ${installedModels
                .map(
                  (model) =>
                    `<option value="${escapeHtml(model.name)}"${getSelectedChatModel() === model.name ? ' selected' : ''}>${escapeHtml(model.name)}</option>`
                )
                .join('')}
            </select>
          </label>
          <label class="field wide">
            <span class="field-label">OpenClaw Workspace</span>
            <input data-ai-field name="workspacePath" value="${escapeHtml(aiDraft.workspacePath || '')}" placeholder="~/RoachNet/storage/openclaw" />
          </label>
          <label class="field">
            <span class="field-label">Ollama Base URL</span>
            <input data-ai-field name="ollamaBaseUrl" value="${escapeHtml(aiDraft.ollamaBaseUrl || '')}" placeholder="http://RoachNet:11434" />
          </label>
          <label class="field">
            <span class="field-label">OpenClaw Base URL</span>
            <input data-ai-field name="openclawBaseUrl" value="${escapeHtml(aiDraft.openclawBaseUrl || '')}" placeholder="http://RoachNet:3001" />
          </label>
        </div>

        <div class="action-row" style="margin-top: 18px;">
          <button class="rn-button primary" data-action="apply-roachclaw" ${installedModels.length ? '' : 'disabled'}>Apply RoachClaw Defaults</button>
          <button class="rn-button ghost" data-action="refresh-ai">Refresh AI Runtime</button>
        </div>

        <div style="margin-top: 18px;" class="log-scroll">
          ${renderAiHints()}
        </div>
      </div>
    </section>
  `
}

function renderChatWorkbench() {
  const sessions = getChatSessions()
  const suggestions = getChatSuggestions()
  const chatModel = getSelectedChatModel()
  const routeLabel = getPreferredChatRouteLabel()
  const messages = Array.isArray(state.activeSession?.messages) ? state.activeSession.messages : []

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>AI Workbench</h2>
          <p>Chat, test prompts, and work through development tasks with your local RoachClaw runtime.</p>
        </div>
        ${statusPill(chatModel ? 'ready' : 'pending')}
      </div>
      <div class="panel-body">
        <div class="chat-layout">
          <aside class="session-sidebar">
            <div class="section-title">Sessions</div>
            <div class="session-list">
              ${
                sessions.length
                  ? sessions
                      .map(
                        (session) => `
                          <button class="session-item ${state.activeSessionId === session.id ? 'active' : ''}" data-action="open-chat-session" data-session-id="${session.id}">
                            <strong>${escapeHtml(session.title || 'New Chat')}</strong>
                            <span>${escapeHtml(session.model || 'local model')}</span>
                          </button>
                        `
                      )
                      .join('')
                  : '<div class="empty-note">No sessions yet. Send a prompt to start the first one.</div>'
              }
            </div>
            ${
              state.activeSessionId
                ? `<button class="rn-button ghost small" data-action="delete-chat-session" data-session-id="${state.activeSessionId}">Delete Session</button>`
                : ''
            }
          </aside>

          <div class="chat-main">
            <div class="chat-toolbar">
              <div class="field-grid">
                <label class="field wide">
                  <span class="field-label">Active Route</span>
                  <input value="${escapeHtml(routeLabel)}" disabled />
                </label>
                <label class="field wide">
                  <span class="field-label">Active Model</span>
                  <input value="${escapeHtml(chatModel)}" disabled />
                </label>
              </div>
            </div>

            <div class="chat-transcript">
              ${
                messages.length
                  ? messages
                      .map(
                        (message) => `
                          <article class="message-bubble ${message.role === 'assistant' ? 'assistant' : message.role === 'system' ? 'system' : 'user'}">
                            <div class="message-role">${escapeHtml(message.role)}</div>
                            <div>${escapeHtml(message.content)}</div>
                          </article>
                        `
                      )
                      .join('')
                  : '<div class="empty-note">Use the workbench to chat, test prompts, or handle local development tasks.</div>'
              }
            </div>

            ${
              suggestions.length
                ? `
                  <div class="suggestion-row">
                    ${suggestions
                      .slice(0, 3)
                      .map(
                        (suggestion) =>
                          `<button class="suggestion-chip" data-action="use-suggestion" data-suggestion="${escapeHtml(suggestion)}">${escapeHtml(suggestion)}</button>`
                      )
                      .join('')}
                  </div>
                `
                : ''
            }

            <label class="field wide" style="margin-top: 14px;">
              <span class="field-label">Prompt</span>
              <textarea data-ui-field="chatInput" class="chat-input" placeholder="Ask RoachNet to code, debug, explain, or work through an offline task...">${escapeHtml(state.chatInput)}</textarea>
            </label>
            <div class="action-row" style="margin-top: 12px;">
              <button class="rn-button primary" data-action="send-chat" ${chatModel ? '' : 'disabled'}>Send Prompt</button>
              <button class="rn-button ghost" data-action="refresh-ai">Refresh AI Runtime</button>
            </div>
          </div>
        </div>
      </div>
    </section>
  `
}

function renderAIStudio(desktopState) {
  if (!desktopState.install?.installed) {
    return `
      <section class="panel">
        <div class="panel-header">
          <div>
            <h2>AI Studio</h2>
            <p>Install RoachNet first to enable local model, skill, and RoachClaw management.</p>
          </div>
          ${statusPill('pending')}
        </div>
        <div class="panel-body">
          <div class="empty-note">After installation, model management, RoachClaw controls, ClawHub skills, and the AI workbench appear here.</div>
        </div>
      </section>
    `
  }

  if (!state.aiState) {
    return `
      <section class="panel">
        <div class="panel-header">
          <div>
            <h2>AI Studio</h2>
            <p>Starting the command deck will make the local AI controls available here.</p>
          </div>
          ${statusPill('standby')}
        </div>
        <div class="panel-body">
          <div class="action-row">
            <button class="rn-button primary" data-action="start-app">Start AI Core</button>
          </div>
        </div>
      </section>
    `
  }

  const errors = [
    getSettledError(state.aiState.systemInfo),
    getSettledError(state.aiState.providers),
    getSettledError(state.aiState.roachclaw),
    getSettledError(state.aiState.installedModels),
    getSettledError(state.aiState.installedSkills),
  ].filter(Boolean)

  return `
    <div class="ai-shell">
      ${
        errors.length
          ? `
            <div class="banner error">
              <div>
                <strong>AI Runtime Errors</strong>
                <div>${escapeHtml(errors.join(' | '))}</div>
              </div>
            </div>
          `
          : ''
      }
      ${renderRoachClawStudio()}
      <div class="ai-dual-grid">
        ${renderModelLibrary()}
        ${renderSkillLibrary()}
      </div>
      ${renderChatWorkbench()}
    </div>
  `
}

function renderAccelerationStudio(desktopState) {
  if (!desktopState.install?.installed) {
    return ''
  }

  const acceleration = getAccelerationData()
  if (!acceleration) {
    return ''
  }

  const config = getEffectiveConfig()
  const apple = acceleration.apple || {}
  const exo = acceleration.distributed?.exo || {}
  const recommendationLines = Array.isArray(acceleration.recommendations)
    ? acceleration.recommendations
    : []

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>Acceleration And Cluster Runtime</h2>
          <p>Apple devices can be steered toward MLX-backed inference, and multi-device clusters can be staged for exo-style execution when it makes sense.</p>
        </div>
        ${statusPill(apple.supported ? 'apple ready' : 'generic host')}
      </div>
      <div class="panel-body">
        <div class="ai-dual-grid">
          <article class="log-card">
            <h3 class="section-title">Apple Silicon Acceleration</h3>
            <div class="field-grid single-column">
              <label class="field wide">
                <span class="field-label">Apple AI Backend</span>
                <select data-config-field name="appleAccelerationBackend">
                  ${['auto', 'ollama', 'mlx']
                    .map(
                      (mode) =>
                        `<option value="${mode}"${config.appleAccelerationBackend === mode ? ' selected' : ''}>${escapeHtml(mode.toUpperCase())}</option>`
                    )
                    .join('')}
                </select>
              </label>
              <label class="field wide">
                <span class="field-label">MLX Server Base URL</span>
                <input data-config-field name="mlxBaseUrl" value="${escapeHtml(config.mlxBaseUrl || '')}" placeholder="http://RoachNet:8080" />
              </label>
              <label class="field wide">
                <span class="field-label">MLX Model ID</span>
                <input data-config-field name="mlxModelId" value="${escapeHtml(config.mlxModelId || '')}" placeholder="qwen3-8b-4bit or another mlx-lm served model id" />
              </label>
            </div>
            <div class="toggle-grid single-column" style="margin-top: 14px;">
              ${renderToggle('installOptionalMlx', 'Install MLX tooling during setup', config.installOptionalMlx)}
            </div>
            <div class="list-stack" style="margin-top: 14px;">
              <div class="list-item">
                <div>
                  <strong>MLX Core</strong>
                  <div class="metric-detail">${escapeHtml(apple.mlx?.version || apple.mlx?.error || 'Not detected')}</div>
                </div>
                ${statusPill(apple.mlx?.installed ? 'installed' : apple.supported ? 'pending' : 'unsupported')}
              </div>
              <div class="list-item">
                <div>
                  <strong>mlx-lm</strong>
                  <div class="metric-detail">${escapeHtml(apple.mlxLm?.version || apple.mlxLm?.error || 'Not detected')}</div>
                </div>
                ${statusPill(apple.mlxLm?.installed ? 'installed' : apple.supported ? 'pending' : 'unsupported')}
              </div>
              <div class="list-item">
                <div>
                  <strong>MLX Server Probe</strong>
                  <div class="metric-detail">${escapeHtml(apple.server?.error || (apple.server?.path ? `${apple.server.path} | HTTP ${apple.server.status}` : 'No probe executed'))}</div>
                </div>
                ${statusPill(apple.server?.reachable ? 'reachable' : apple.supported ? 'standby' : 'unsupported')}
              </div>
            </div>
            <div class="action-row" style="margin-top: 14px;">
              <button class="rn-button secondary" data-action="save-config">Save Acceleration Profile</button>
              <button class="rn-button ghost" data-action="open-mlx-docs">MLX Docs</button>
            </div>
          </article>

          <article class="log-card">
            <h3 class="section-title">Distributed Inference</h3>
            <div class="metric-detail" style="margin-bottom: 14px;">
              Keep this disabled for single-machine operation. Enable exo only when you want to spread inference across multiple devices.
            </div>
            <div class="field-grid">
              <label class="field">
                <span class="field-label">Cluster Backend</span>
                <select data-config-field name="distributedInferenceBackend">
                  ${['disabled', 'exo']
                    .map(
                      (mode) =>
                        `<option value="${mode}"${config.distributedInferenceBackend === mode ? ' selected' : ''}>${escapeHtml(mode.toUpperCase())}</option>`
                    )
                    .join('')}
                </select>
              </label>
              <label class="field">
                <span class="field-label">exo Node Role</span>
                <select data-config-field name="exoNodeRole">
                  ${['auto', 'coordinator', 'worker', 'hybrid']
                    .map(
                      (mode) =>
                        `<option value="${mode}"${config.exoNodeRole === mode ? ' selected' : ''}>${escapeHtml(mode.toUpperCase())}</option>`
                    )
                    .join('')}
                </select>
              </label>
              <label class="field wide">
                <span class="field-label">exo Base URL</span>
                <input data-config-field name="exoBaseUrl" value="${escapeHtml(config.exoBaseUrl || '')}" placeholder="http://RoachNet:52415" />
              </label>
              <label class="field wide">
                <span class="field-label">exo Model ID</span>
                <input data-config-field name="exoModelId" value="${escapeHtml(config.exoModelId || '')}" placeholder="llama-3.2-3b or another exo-exposed model id" />
              </label>
            </div>
            <div class="toggle-grid single-column" style="margin-top: 14px;">
              ${renderToggle('exoAutoStart', 'Auto-start exo helper when implemented', config.exoAutoStart)}
            </div>
            <div class="list-stack" style="margin-top: 14px;">
              <div class="list-item">
                <div>
                  <strong>Cluster Endpoint</strong>
                  <div class="metric-detail">${escapeHtml(exo.baseUrl || 'Not configured')}</div>
                </div>
                ${statusPill(
                  config.distributedInferenceBackend === 'disabled'
                    ? 'disabled'
                    : exo.reachable
                      ? 'reachable'
                      : 'pending'
                )}
              </div>
              <div class="list-item">
                <div>
                  <strong>Cluster Overhead Mode</strong>
                  <div class="metric-detail">${escapeHtml(
                    config.distributedInferenceBackend === 'disabled'
                      ? 'No exo probing or cluster coordination will run in single-machine mode.'
                      : exo.error || (exo.path ? `${exo.path} | HTTP ${exo.status}` : 'No probe executed')
                  )}</div>
                </div>
                ${statusPill(
                  config.distributedInferenceBackend === 'disabled'
                    ? 'single-device'
                    : exo.reachable
                      ? 'available'
                      : 'standby'
                )}
              </div>
            </div>
            <div class="action-row" style="margin-top: 14px;">
              <button class="rn-button secondary" data-action="save-config">Save Cluster Profile</button>
              <button class="rn-button ghost" data-action="open-exo-docs">exo Repo</button>
            </div>
          </article>
        </div>

        <div class="log-scroll" style="margin-top: 18px;">
          ${
            recommendationLines.length
              ? recommendationLines
                  .map((line) => `<div class="log-line">${escapeHtml(line)}</div>`)
                  .join('')
              : '<div class="empty-note">Acceleration guidance will appear here as the runtime profile matures.</div>'
          }
        </div>
      </div>
    </section>
  `
}

function renderKnowledgeStudio(desktopState) {
  if (!desktopState.install?.installed) {
    return ''
  }

  const files = getKnowledgeFiles()
  const jobs = getKnowledgeJobs()
  const errors = [
    getSettledError(state.knowledgeState?.files),
    getSettledError(state.knowledgeState?.activeJobs),
  ].filter(Boolean)

  return `
    <section class="panel">
      <div class="panel-header">
        <div>
          <h2>Knowledge Workspaces</h2>
          <p>Native ingestion and storage controls for RoachNet's local knowledge base, aligned with the AnythingLLM-style workspace direction.</p>
        </div>
        ${statusPill(files.length ? 'ready' : 'pending')}
      </div>
      <div class="panel-body">
        ${
          errors.length
            ? `
              <div class="banner error" style="margin-bottom: 18px;">
                <div>
                  <strong>Knowledge Runtime Errors</strong>
                  <div>${escapeHtml(errors.join(' | '))}</div>
                </div>
              </div>
            `
            : ''
        }
        <div class="action-row">
          <button class="rn-button primary" data-action="upload-knowledge-files">Add Files</button>
          <button class="rn-button secondary" data-action="scan-knowledge-storage">Scan Storage</button>
          <button class="rn-button ghost" data-action="refresh-knowledge">Refresh Knowledge State</button>
        </div>

        <div class="ai-dual-grid" style="margin-top: 18px;">
          <article class="log-card">
            <h3 class="section-title">Indexed Sources</h3>
            <div class="list-stack">
              ${
                files.length
                  ? files
                      .map(
                        (source) => `
                          <div class="list-item">
                            <div>
                              <strong>${escapeHtml(source.split('/').pop() || source)}</strong>
                              <div class="metric-detail">${escapeHtml(source)}</div>
                            </div>
                            <div class="inline-actions">
                              <button class="rn-button ghost small" data-action="delete-knowledge-file" data-source="${escapeHtml(source)}">Remove</button>
                            </div>
                          </div>
                        `
                      )
                      .join('')
                  : '<div class="empty-note">No knowledge documents have been indexed yet.</div>'
              }
            </div>
          </article>

          <article class="log-card">
            <h3 class="section-title">Embedding Jobs</h3>
            <div class="list-stack">
              ${
                jobs.length
                  ? jobs
                      .map(
                        (job) => `
                          <div class="list-item">
                            <div>
                              <strong>${escapeHtml(job.fileName || job.filePath || 'Embedding Job')}</strong>
                              <div class="metric-detail">${escapeHtml(job.status || 'running')}${job.progress !== undefined ? ` | ${escapeHtml(job.progress)}%` : ''}</div>
                            </div>
                            ${statusPill(job.status || 'running')}
                          </div>
                        `
                      )
                      .join('')
                  : '<div class="empty-note">No active embedding jobs right now.</div>'
              }
            </div>
          </article>
        </div>
      </div>
    </section>
  `
}

function renderFooter(desktopState) {
  return `
    <footer class="native-footer">
      <div>
        <strong>RoachNet</strong>
        <span> Native suite shell</span>
      </div>
      <div>
        Version ${escapeHtml(desktopState.shell.version)}
      </div>
    </footer>
  `
}

function renderSetupGate(desktopState) {
  return `
    <section class="setup-gate panel">
      <div class="panel-header">
        <div>
          <h2>Finish setup to unlock RoachNet</h2>
          <p>The main app stays locked until the separate setup app completes installation.</p>
        </div>
        ${statusPill('setup')}
      </div>
      <div class="panel-body">
        <div class="content-stack">
          <div class="empty-note">
            Open RoachNet Setup, complete installation, then come back here.
          </div>
          <div class="action-row">
            <button class="rn-button primary" data-action="open-installer-helper">Open RoachNet Setup</button>
            <button class="rn-button ghost" data-action="open-releases">Release Downloads</button>
          </div>
          ${renderTaskPanel(desktopState.setup?.lastCompletedTask, 'Recent Setup Activity')}
        </div>
      </div>
    </section>
  `
}

function render() {
  if (!root) {
    return
  }

  if (!state.desktopState) {
    root.innerHTML = `
      <section class="panel">
        <div class="panel-body">
          <div class="empty-note">Booting the native RoachNet shell...</div>
        </div>
      </section>
    `
    return
  }

  const desktopState = state.desktopState
  const runtime = desktopState.runtime || {}
  const updater = desktopState.updater || {}
  const runtimeStatus = getRuntimeStatus(runtime)

  let markup = `
    <div class="window-dragbar" aria-hidden="true">
      <div class="window-dragbar__rail"></div>
      <div class="window-dragbar__label">Drag Window</div>
      <div class="window-dragbar__rail"></div>
    </div>

    <header class="shell-header">
      <div class="brand-lockup">
        <div class="brand-badge">
          <img src="../assets/icon.png" alt="RoachNet" />
        </div>
        <div class="brand-text">
          <h1>RoachNet</h1>
          <p>Local-first suite for RoachClaw, runtime control, chat, and knowledge work.</p>
        </div>
      </div>
      <div class="header-actions">
        <button class="rn-button secondary" data-action="toggle-roachcast">RoachCast</button>
        <span class="native-chip">Mode <strong>${escapeHtml(runtime.mode || 'idle')}</strong></span>
        <span class="native-chip">Updates <strong>${escapeHtml((updater.releaseChannel || 'stable').toUpperCase())}</strong></span>
        <span class="native-chip">Runtime <strong>${escapeHtml(runtimeStatus.label)}</strong></span>
      </div>
    </header>

    ${
      state.error
        ? `
          <div class="banner error">
            <div>
              <strong>Native Shell Error</strong>
              <div>${escapeHtml(state.error)}</div>
            </div>
          </div>
        `
        : ''
    }

    <div class="workspace-shell">
      ${renderSidebarNav(desktopState)}
      <div class="workspace-stage">
        ${renderPaneSpotlight(desktopState)}
        ${renderActivePane(desktopState)}
      </div>
    </div>

    ${renderFooter(desktopState)}
    ${renderRoachCast()}
    ${renderIntroOverlay()}
  `

  if (!desktopState.install?.installed) {
    markup = `
      <div class="window-dragbar" aria-hidden="true">
        <div class="window-dragbar__rail"></div>
        <div class="window-dragbar__label">Drag Window</div>
        <div class="window-dragbar__rail"></div>
      </div>

      <header class="shell-header">
        <div class="brand-lockup">
          <div class="brand-badge">
            <img src="../assets/icon.png" alt="RoachNet" />
          </div>
        <div class="brand-text">
          <h1>RoachNet</h1>
          <p>Local-first suite for RoachClaw, runtime control, chat, and knowledge work.</p>
        </div>
      </div>
      </header>

      ${renderSetupGate(desktopState)}
      ${renderFooter(desktopState)}
    `
  }

  if (markup === lastRenderedMarkup) {
    return
  }

  lastRenderedMarkup = markup
  root.innerHTML = markup
  bindActions()
}

function updateDraftFromForm() {
  const config = { ...getEffectiveConfig() }

  for (const element of root.querySelectorAll('[data-config-field][name]')) {
    if (element.type === 'checkbox') {
      config[element.name] = element.checked
      continue
    }

    config[element.name] = element.value
  }

  state.draftConfig = config
  return config
}

function updateAiDraftFromForm() {
  const aiDraft = { ...getEffectiveAiDraft() }

  for (const element of root.querySelectorAll('[data-ai-field][name]')) {
    if (element.type === 'checkbox') {
      aiDraft[element.name] = element.checked
      continue
    }

    aiDraft[element.name] = element.value
  }

  const modelSearchInput = root.querySelector('[data-ui-field="modelSearchQuery"]')
  const skillSearchInput = root.querySelector('[data-ui-field="skillSearchQuery"]')
  const chatInput = root.querySelector('[data-ui-field="chatInput"]')
  const roachCastInput = root.querySelector('[data-ui-field="roachCastQuery"]')

  state.aiDraft = aiDraft
  state.modelSearchQuery = modelSearchInput ? modelSearchInput.value : state.modelSearchQuery
  state.skillSearchQuery = skillSearchInput ? skillSearchInput.value : state.skillSearchQuery
  state.chatInput = chatInput ? chatInput.value : state.chatInput
  state.roachCastQuery = roachCastInput ? roachCastInput.value : state.roachCastQuery
  return aiDraft
}

async function withBusy(action, work) {
  if (state.busyAction) {
    return
  }

  state.busyAction = action
  state.error = ''
  render()

  try {
    await work()
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error)
  } finally {
    state.busyAction = ''
    await refreshState({ preserveDraft: true, preserveAiDraft: true })
  }
}

async function loadActiveSession(sessionId, options = {}) {
  if (!sessionId) {
    state.activeSessionId = null
    state.activeSession = null
    return
  }

  state.activeSessionId = Number(sessionId)
  state.activeSession = await desktop.getChatSession(Number(sessionId))
  if (!options.preserveModel) {
    state.aiDraft = {
      ...getEffectiveAiDraft(),
      chatModel: state.activeSession?.model || getSelectedChatModel(),
    }
  }
}

function bindActions() {
  for (const field of root.querySelectorAll('[data-config-field], [data-ai-field], [data-ui-field]')) {
    field.addEventListener('input', () => {
      updateDraftFromForm()
      updateAiDraftFromForm()
    })
    field.addEventListener('change', () => {
      updateDraftFromForm()
      updateAiDraftFromForm()
    })
  }

  for (const button of root.querySelectorAll('[data-action]')) {
    if (state.busyAction) {
      button.disabled = true
    }

    button.addEventListener('click', async (event) => {
      if (button.dataset.action === 'close-roachcast-overlay' && event.target === button) {
        closeRoachCast()
        return
      }

      const config = updateDraftFromForm()
      const aiDraft = updateAiDraftFromForm()

      if (button.dataset.action === 'toggle-roachcast') {
        if (state.roachCastOpen) {
          closeRoachCast()
        } else {
          openRoachCast()
        }
        return
      }

      if (button.dataset.action === 'set-pane') {
        state.activePane = button.dataset.pane || 'overview'
        render()
        return
      }

      if (button.dataset.action === 'close-roachcast') {
        closeRoachCast()
        return
      }

      if (button.dataset.action === 'dismiss-intro') {
        await completeIntroTour()
        return
      }

      if (button.dataset.action === 'run-roachcast-command') {
        await runRoachCastCommand(button.dataset.commandId)
        return
      }

      switch (button.dataset.action) {
        case 'save-config':
          await withBusy('save-config', async () => {
            await desktop.saveConfig(config)
          })
          break
        case 'open-installer-helper':
          await withBusy('open-installer-helper', async () => {
            await desktop.openInstallerHelper()
          })
          break
        case 'start-container-runtime':
          await withBusy('start-container-runtime', async () => {
            await desktop.startContainerRuntime()
          })
          break
        case 'start-app':
          await withBusy('start-app', async () => {
            if (button.disabled) {
              return
            }

            await desktop.startMode('app')
          })
          break
        case 'stop-runtime':
          await withBusy('stop-runtime', async () => {
            await desktop.stopRuntime()
            state.aiState = null
            state.activeSession = null
          })
          break
        case 'check-updates':
          await withBusy('check-updates', async () => {
            await desktop.checkForUpdates()
          })
          break
        case 'open-install-folder':
          await withBusy('open-install-folder', async () => {
            if (button.disabled) {
              return
            }

            await desktop.openInstallFolder()
          })
          break
        case 'open-releases':
          await withBusy('open-releases', async () => {
            await desktop.openReleaseDownloads()
          })
          break
        case 'open-mlx-docs':
          await withBusy('open-mlx-docs', async () => {
            await desktop.openMlxDocs()
          })
          break
        case 'open-exo-docs':
          await withBusy('open-exo-docs', async () => {
            await desktop.openExoDocs()
          })
          break
        case 'refresh-ai':
          await withBusy('refresh-ai', async () => {
            await refreshAIState({ force: true })
          })
          break
        case 'apply-roachclaw':
          await withBusy('apply-roachclaw', async () => {
            if (!aiDraft.model) {
              throw new Error('Select a local model first.')
            }

            await desktop.applyRoachClaw({
              model: aiDraft.model,
              workspacePath: aiDraft.workspacePath,
              ollamaBaseUrl: aiDraft.ollamaBaseUrl,
              openclawBaseUrl: aiDraft.openclawBaseUrl,
            })
          })
          break
        case 'search-models':
          await withBusy('search-models', async () => {
            state.modelSearchResults = await desktop.searchModels({
              query: state.modelSearchQuery,
              recommendedOnly: false,
              limit: 12,
              sort: 'pulls',
            })
          })
          break
        case 'search-models-recommended':
          await withBusy('search-models-recommended', async () => {
            state.modelSearchResults = await desktop.searchModels({
              query: state.modelSearchQuery,
              recommendedOnly: true,
              limit: 12,
              sort: 'pulls',
            })
          })
          break
        case 'install-model':
          await withBusy('install-model', async () => {
            await desktop.downloadModel(button.dataset.model)
          })
          break
        case 'delete-model':
          await withBusy('delete-model', async () => {
            await desktop.deleteModel(button.dataset.model)
            if (getSelectedChatModel() === button.dataset.model) {
              state.aiDraft = {
                ...getEffectiveAiDraft(),
                chatModel: '',
                model: '',
              }
            }
          })
          break
        case 'search-skills':
          await withBusy('search-skills', async () => {
            state.skillSearchResults = await desktop.searchSkills({
              query: state.skillSearchQuery,
              limit: 8,
            })
          })
          break
        case 'install-skill':
          await withBusy('install-skill', async () => {
            await desktop.installSkill({
              slug: button.dataset.skill,
            })
          })
          break
        case 'open-chat-session':
          await withBusy('open-chat-session', async () => {
            await loadActiveSession(button.dataset.sessionId)
          })
          break
        case 'delete-chat-session':
          await withBusy('delete-chat-session', async () => {
            await desktop.deleteChatSession(button.dataset.sessionId)
            state.activeSessionId = null
            state.activeSession = null
          })
          break
        case 'use-suggestion':
          state.chatInput = button.dataset.suggestion || ''
          render()
          break
        case 'send-chat':
          await withBusy('send-chat', async () => {
            const prompt = state.chatInput.trim()
            const model = getSelectedChatModel()

            if (!prompt) {
              throw new Error('Enter a prompt first.')
            }

            if (!model) {
              throw new Error('Select a local model first.')
            }

            const result = await desktop.sendChatMessage({
              sessionId: state.activeSessionId,
              model,
              content: prompt,
            })

            state.chatInput = ''
            state.activeSessionId = result.sessionId
            state.activeSession = result.session
            state.aiDraft = {
              ...getEffectiveAiDraft(),
              chatModel: model,
            }
          })
          break
        case 'refresh-knowledge':
          await withBusy('refresh-knowledge', async () => {
            await refreshKnowledgeState({ force: true })
          })
          break
        case 'scan-knowledge-storage':
          await withBusy('scan-knowledge-storage', async () => {
            await desktop.scanKnowledgeStorage()
          })
          break
        case 'upload-knowledge-files':
          await withBusy('upload-knowledge-files', async () => {
            await desktop.selectAndUploadKnowledgeFiles()
          })
          break
        case 'delete-knowledge-file':
          await withBusy('delete-knowledge-file', async () => {
            await desktop.deleteKnowledgeFile(button.dataset.source)
          })
          break
        default:
          break
      }
    })
  }

  const roachCastInput = root.querySelector('[data-ui-field="roachCastQuery"]')
  if (state.roachCastOpen && roachCastInput) {
    roachCastInput.focus()
    roachCastInput.setSelectionRange(roachCastInput.value.length, roachCastInput.value.length)
  }
}

function handleGlobalKeydown(event) {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault()
    if (state.roachCastOpen) {
      closeRoachCast()
    } else {
      openRoachCast()
    }
    return
  }

  if (!state.roachCastOpen) {
    return
  }

  const commands = getFilteredRoachCastCommands()

  if (event.key === 'Escape') {
    event.preventDefault()
    closeRoachCast()
    return
  }

  if (event.key === 'ArrowDown') {
    event.preventDefault()
    state.roachCastSelectedIndex = clamp(
      state.roachCastSelectedIndex + 1,
      0,
      Math.max(commands.length - 1, 0)
    )
    render()
    return
  }

  if (event.key === 'ArrowUp') {
    event.preventDefault()
    state.roachCastSelectedIndex = clamp(
      state.roachCastSelectedIndex - 1,
      0,
      Math.max(commands.length - 1, 0)
    )
    render()
    return
  }

  if (event.key === 'Enter') {
    const selectedCommand = getSelectedRoachCastCommand()
    if (!selectedCommand || selectedCommand.disabled) {
      return
    }

    event.preventDefault()
    runRoachCastCommand(selectedCommand.id).catch((error) => {
      state.error = error instanceof Error ? error.message : String(error)
      render()
    })
  }
}

async function maybeAutoLaunchAfterInstall() {
  const desktopState = state.desktopState
  const task = desktopState?.setup?.lastCompletedTask
  const config = desktopState?.config
  const taskId = createTaskId(task)

  if (
    !taskId ||
    task.status !== 'completed' ||
    !config?.autoLaunch ||
    !desktopState.install?.installed ||
    desktopState.runtime?.mode === 'app' ||
    state.autoLaunchedTaskId === taskId
  ) {
    return
  }

  state.autoLaunchedTaskId = taskId

  try {
    await desktop.startMode('app')
    state.desktopState = await desktop.getState()
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error)
  }
}

function clearIntroTimers() {
  if (introAdvanceTimer) {
    window.clearInterval(introAdvanceTimer)
    introAdvanceTimer = null
  }

  if (introDismissTimer) {
    window.clearTimeout(introDismissTimer)
    introDismissTimer = null
  }
}

async function completeIntroTour() {
  clearIntroTimers()
  state.introVisible = false
  state.introTimerStarted = false
  state.introStepIndex = 0
  render()

  await desktop
    .saveConfig({
      pendingLaunchIntro: false,
      introCompletedAt: new Date().toISOString(),
    })
    .catch(() => {})
}

function maybeSyncIntroState() {
  const config = state.desktopState?.config
  const runtime = state.desktopState?.runtime

  if (state.introVisible && state.introTimerStarted) {
    return
  }

  if (!config?.pendingLaunchIntro || runtime?.mode !== 'app') {
    if (!config?.pendingLaunchIntro) {
      clearIntroTimers()
      state.introVisible = false
      state.introTimerStarted = false
      state.introStepIndex = 0
    }
    return
  }

  clearIntroTimers()
  state.introVisible = true
  state.introTimerStarted = true
  state.introStepIndex = 0
  render()

  introAdvanceTimer = window.setInterval(() => {
    if (state.introStepIndex >= ROACHNET_TOUR_STEPS.length - 1) {
      return
    }

    state.introStepIndex += 1
    render()
  }, 2200)

  introDismissTimer = window.setTimeout(() => {
    completeIntroTour().catch(() => {})
  }, 9800)
}

async function maybeApplyInstallerRoachClawDefaults() {
  const config = state.desktopState?.config
  const runtime = state.desktopState?.runtime
  const roachClaw = getRoachClawStatus()

  if (!config?.installRoachClaw || !config?.pendingRoachClawSetup || runtime?.mode !== 'app') {
    if (!config?.pendingRoachClawSetup) {
      state.roachClawBootstrapStarted = false
    }
    return
  }

  if (state.roachClawBootstrapStarted) {
    return
  }

  state.roachClawBootstrapStarted = true

  const model =
    (config.roachClawDefaultModel || roachClaw?.defaultModel || 'qwen2.5-coder:7b').trim()
  const workspacePath =
    roachClaw?.workspacePath ||
    `${(config.installPath || '').replace(/\/+$/, '')}/storage/openclaw`
  const ollamaBaseUrl = roachClaw?.ollama?.baseUrl || 'http://RoachNet:11434'
  const openclawBaseUrl = roachClaw?.openclaw?.baseUrl || 'http://RoachNet:3001'

  try {
    await desktop.applyRoachClaw({
      model,
      workspacePath,
      ollamaBaseUrl,
      openclawBaseUrl,
    })
    await desktop.saveConfig({
      installRoachClaw: true,
      installOptionalOllama: true,
      installOptionalOpenClaw: true,
      roachClawDefaultModel: model,
      pendingRoachClawSetup: false,
      roachClawOnboardingCompletedAt: new Date().toISOString(),
    })
    state.desktopState = await desktop.getState()
    await refreshAIState({ force: true, preserveAiDraft: true, forceActiveSession: true })
  } catch (error) {
    state.error =
      error instanceof Error
        ? error.message
        : 'RoachClaw could not be finished automatically on first launch.'
    state.roachClawBootstrapStarted = false
  }
}

async function refreshAIState(options = {}) {
  if (!state.desktopState?.install?.installed) {
    state.aiState = null
    state.knowledgeState = null
    state.activeSession = null
    state.activeSessionId = null
    return
  }

  if (state.desktopState?.setup?.activeTask && !options.force) {
    return
  }

  state.aiState = await desktop.getAIState()
  syncAiDraft(!options.preserveAiDraft)

  const sessions = getChatSessions()
  if (!sessions.length) {
    state.activeSessionId = null
    state.activeSession = null
    return
  }

  if (!state.activeSessionId || !sessions.some((session) => session.id === state.activeSessionId)) {
    await loadActiveSession(sessions[0].id, { preserveModel: true })
    return
  }

  if (!state.activeSession || options.forceActiveSession) {
    await loadActiveSession(state.activeSessionId, { preserveModel: true })
  }
}

async function refreshKnowledgeState(options = {}) {
  if (!state.desktopState?.install?.installed) {
    state.knowledgeState = null
    return
  }

  if (state.desktopState?.setup?.activeTask && !options.force) {
    return
  }

  state.knowledgeState = await desktop.getKnowledgeState()
}

async function refreshState(options = {}) {
  state.desktopState = await desktop.getState()

  if (!options.preserveDraft || !state.draftConfig) {
    syncDraftConfig(true)
  }

  await maybeAutoLaunchAfterInstall()
  maybeSyncIntroState()

  const shouldRefreshAi =
    state.desktopState.install?.installed &&
    (state.activePane === 'overview' ||
      state.activePane === 'ai' ||
      state.roachCastOpen ||
      state.introVisible ||
      Boolean(state.aiState))

  const shouldRefreshKnowledge =
    state.desktopState.install?.installed &&
    (state.activePane === 'knowledge' || Boolean(state.knowledgeState))

  if (state.desktopState.install?.installed) {
    try {
      if (shouldRefreshAi) {
        await refreshAIState({
          preserveAiDraft: options.preserveAiDraft,
          forceActiveSession: options.forceActiveSession,
        })
        await maybeApplyInstallerRoachClawDefaults()
      }

      if (shouldRefreshKnowledge) {
        await refreshKnowledgeState({
          force: options.forceKnowledge,
        })
      }
    } catch (error) {
      state.aiState = null
      state.knowledgeState = null
      state.error = error instanceof Error ? error.message : String(error)
    }
  } else {
    state.aiState = null
    state.knowledgeState = null
  }

  render()
}

async function boot() {
  render()
  window.addEventListener('keydown', handleGlobalKeydown)

  desktop.onStateChange((nextState) => {
    state.desktopState = nextState
    syncDraftConfig(!state.draftConfig)
    const shouldRefreshAi =
      state.activePane === 'overview' ||
      state.activePane === 'ai' ||
      state.roachCastOpen ||
      state.introVisible
    const shouldRefreshKnowledge = state.activePane === 'knowledge'
    maybeAutoLaunchAfterInstall()
      .then(() => {
        maybeSyncIntroState()
      })
      .then(() =>
        shouldRefreshAi ? refreshAIState({ preserveAiDraft: true }) : Promise.resolve()
      )
      .then(() => (shouldRefreshAi ? maybeApplyInstallerRoachClawDefaults() : Promise.resolve()))
      .then(() => (shouldRefreshKnowledge ? refreshKnowledgeState({ force: true }) : Promise.resolve()))
      .catch(() => {})
      .finally(() => {
        render()
      })
  })

  await refreshState()
  window.setInterval(() => {
    const active = document.activeElement
    if (active?.matches?.('[data-config-field], [data-ai-field], [data-ui-field], input, select, textarea')) {
      return
    }

    refreshState({ preserveDraft: true, preserveAiDraft: true, forceActiveSession: false }).catch(() => {})
  }, 6000)
}

boot().catch((error) => {
  state.error = error instanceof Error ? error.message : String(error)
  render()
})
