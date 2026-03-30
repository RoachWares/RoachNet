const setup = window.roachnetSetup || null
const root = document.querySelector('#app')
let refreshIntervalId = null

const state = {
  setupState: null,
  draftConfig: null,
  stepIndex: 0,
  busyAction: '',
  error: '',
  finishSequenceVisible: false,
  finishSequenceStarted: false,
}

const steps = [
  {
    id: 'welcome',
    label: 'Welcome',
    title: 'RoachNet Setup',
    detail: 'A calm first-run install tuned for your machine.',
  },
  {
    id: 'machine',
    label: 'Check',
    title: 'Machine check',
    detail: 'Confirm hardware, package tools, and what is already ready.',
  },
  {
    id: 'runtime',
    label: 'Runtime',
    title: 'Container runtime',
    detail: 'Prepare Docker/Desktop and the RoachNet support stack automatically.',
  },
  {
    id: 'ai',
    label: 'RoachClaw',
    title: 'Local AI defaults',
    detail: 'Prepare the RoachClaw local AI stack.',
  },
  {
    id: 'install',
    label: 'Install',
    title: 'Install RoachNet',
    detail: 'Pick the destination and finish the guided setup.',
  },
  {
    id: 'finish',
    label: 'Launch',
    title: 'RoachNet is ready',
    detail: 'Play the first-launch reveal and hand off into the main app.',
  },
]

function renderWindowDragbar() {
  return `
    <div class="wizard-dragbar" aria-hidden="true">
      <div class="wizard-dragbar__rail"></div>
      <div class="wizard-dragbar__label">RoachNet Setup</div>
      <div class="wizard-dragbar__rail"></div>
    </div>
  `
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

function getSetupConfig() {
  return state.draftConfig || state.setupState?.config || {}
}

function getTask() {
  return state.setupState?.activeTask || state.setupState?.lastCompletedTask || null
}

function isInstallComplete() {
  const task = getTask()
  return Boolean(task?.status === 'completed' && task?.result?.installPath)
}

function normalizeStepIndex(index) {
  return Math.max(0, Math.min(index, steps.length - 1))
}

function getVisibleStepIndex() {
  if (isInstallComplete()) {
    return steps.findIndex((step) => step.id === 'finish')
  }

  return normalizeStepIndex(state.stepIndex)
}

function getCurrentStep() {
  return steps[getVisibleStepIndex()]
}

function syncDraft(force = false) {
  if (!state.setupState?.config) {
    return
  }

  if (!state.draftConfig || force) {
    state.draftConfig = { ...state.setupState.config }
  }
}

function updateDraftFromForm() {
  const config = { ...getSetupConfig() }

  for (const field of root.querySelectorAll('[data-config-field]')) {
    if (field.type === 'checkbox') {
      config[field.name] = Boolean(field.checked)
    } else {
      config[field.name] = field.value
    }
  }

  state.draftConfig = config
  return config
}

function getStepStatus(index) {
  const visibleIndex = getVisibleStepIndex()
  if (index < visibleIndex) {
    return 'done'
  }
  if (index === visibleIndex) {
    return 'active'
  }
  return 'upcoming'
}

function renderStepRail() {
  const activeIndex = getVisibleStepIndex()
  return `
    <aside class="wizard-rail">
      <div class="rail-brand">
        <div class="rail-mark-shell">
          <img src="../assets/icon.png" alt="RoachNet" />
        </div>
        <div>
          <div class="rail-kicker">Installer Helper</div>
          <h1>RoachNet Setup</h1>
          <p>A guided installer for RoachNet, designed to feel clean, clear, and production-ready from the first screen.</p>
        </div>
      </div>

      <div class="rail-progress">
        <div class="rail-progress-bar">
          <div class="rail-progress-fill" style="width:${((activeIndex + 1) / steps.length) * 100}%"></div>
        </div>
        <div class="rail-progress-meta">Step ${activeIndex + 1} of ${steps.length}</div>
      </div>

      <div class="step-list">
        ${steps
          .map((step, index) => {
            const status = getStepStatus(index)
            return `
              <button class="step-chip step-chip--${status}" data-step-index="${index}">
                <span class="step-chip__index">${String(index + 1).padStart(2, '0')}</span>
                <span class="step-chip__copy">
                  <strong>${escapeHtml(step.label)}</strong>
                  <span>${escapeHtml(step.detail)}</span>
                </span>
              </button>
            `
          })
          .join('')}
      </div>
    </aside>
  `
}

function renderStatusCard(label, value, detail) {
  return `
    <article class="status-card">
      <span class="status-card__label">${escapeHtml(label)}</span>
      <strong>${escapeHtml(value)}</strong>
      <span class="status-card__detail">${escapeHtml(detail)}</span>
    </article>
  `
}

function renderGuideCard(title, body, items = []) {
  return `
    <section class="guide-card">
      <div class="hero-kicker">What Happens Here</div>
      <h3>${escapeHtml(title)}</h3>
      <p>${escapeHtml(body)}</p>
      ${
        items.length
          ? `<ul class="guide-list">${items
              .map((item) => `<li>${escapeHtml(item)}</li>`)
              .join('')}</ul>`
          : ''
      }
    </section>
  `
}

function renderWelcomeStep() {
  return `
    <section class="wizard-panel wizard-hero">
      <div class="hero-copy">
        <div class="hero-kicker">RoachNet Offline Command Center</div>
        <h2>Set everything up once. Launch straight into the real app after that.</h2>
        <p>
          RoachNet Setup will inspect your machine, install or update what is needed, stand up the
          support runtime, prepare RoachClaw, and then hand off to the main RoachNet experience.
        </p>
      </div>
      <div class="hero-stage">
        <div class="hero-mark">
          <div class="hero-ring hero-ring--outer"></div>
          <div class="hero-ring hero-ring--inner"></div>
          <img src="../assets/icon.png" alt="RoachNet" />
        </div>
      </div>
      <div class="hero-grid">
        ${renderStatusCard('Setup Flow', 'Guided Native Wizard', 'No raw terminal steps required unless recovery is needed.')}
        ${renderStatusCard('Runtime', 'Integrated Container Runtime', 'Support services are prepared automatically and kept inside the RoachNet install path.')}
        ${renderStatusCard('AI Stack', 'RoachClaw', 'Ollama and OpenClaw are prepared together as one local AI path.')}
      </div>
    </section>
  `
}

function renderMachineStep() {
  const setupState = state.setupState
  const deps = setupState?.dependencies || []
  const readyCount = deps.filter((dependency) => dependency.available && !dependency.needsUpdate).length
  const needsAttention = deps.filter((dependency) => !dependency.available || dependency.needsUpdate)

  return `
    <section class="wizard-panel">
      <div class="section-head">
        <div>
          <div class="hero-kicker">Machine Check</div>
          <h2>What RoachNet found on this machine</h2>
        </div>
        <div class="badge">${readyCount}/${deps.length} ready</div>
      </div>

      <div class="host-grid">
        ${renderStatusCard('Operating System', setupState?.system?.osLabel || 'Unknown', `${setupState?.system?.arch || 'Unknown'} architecture`)}
        ${renderStatusCard('Package Manager', setupState?.system?.packageManager?.label || 'Unknown', 'Used for automatic prerequisite install and updates.')}
        ${renderStatusCard('Workspace Source', setupState?.system?.currentWorkspaceSourceAvailable ? 'Available' : 'Clone Only', 'Developer source mode is optional.')}
        ${renderStatusCard('Install Target', setupState?.installPath || 'Unset', 'You can change this before install.')}
        ${renderStatusCard('Desktop App Target', setupState?.nativeApp?.installPath || 'Unset', 'The native app is installed inside the RoachNet folder by default to keep the setup contained.')}
      </div>

      ${renderGuideCard(
        needsAttention.length ? 'A few things still need attention' : 'This machine is in good shape',
        needsAttention.length
          ? 'RoachNet Setup can install or update the remaining prerequisites automatically when you continue.'
          : 'Most prerequisites are already available, so setup should stay fast and straightforward.',
        [
          `Ready now: ${readyCount} of ${deps.length}`,
          needsAttention.length
            ? `Will be handled automatically: ${needsAttention.map((dependency) => dependency.label).join(', ')}`
            : 'No required blockers detected.',
        ]
      )}

      <details class="details-card" ${needsAttention.length ? 'open' : ''}>
        <summary>Dependency details</summary>
        <div class="dependency-grid">
          ${deps
            .map((dependency) => {
              const tone = dependency.available && !dependency.needsUpdate ? 'ok' : 'warn'
              const stateLabel = dependency.needsUpdate
                ? 'Update Required'
                : dependency.available
                  ? 'Ready'
                  : dependency.required
                    ? 'Missing'
                    : 'Optional'

              return `
                <article class="dependency-card dependency-card--${tone}">
                  <div class="dependency-card__top">
                    <strong>${escapeHtml(dependency.label)}</strong>
                    <span>${escapeHtml(stateLabel)}</span>
                  </div>
                  <div class="dependency-card__meta">
                    ${escapeHtml(dependency.path || 'Not detected')}
                    ${
                      dependency.version
                        ? `<br />Version ${escapeHtml(dependency.version)}${dependency.minimumVersion ? ` · needs ${escapeHtml(dependency.minimumVersion)}` : ''}`
                        : dependency.minimumVersion
                          ? `<br />Requires ${escapeHtml(dependency.minimumVersion)}`
                          : ''
                    }
                  </div>
                  ${
                    dependency.notes
                      ? `<div class="dependency-card__note">${escapeHtml(dependency.notes)}</div>`
                      : ''
                  }
                </article>
              `
            })
            .join('')}
        </div>
      </details>
    </section>
  `
}

function renderRuntimeStep() {
  const runtime = state.setupState?.containerRuntime

  return `
    <section class="wizard-panel">
      <div class="section-head">
        <div>
          <div class="hero-kicker">Container Runtime</div>
          <h2>Automated Docker/Desktop bootstrap</h2>
          <p class="section-copy">
            RoachNet keeps support services containerized, but the helper owns the setup,
            startup, and health checks so the user is not dropped into manual terminal work.
          </p>
        </div>
        <div class="badge ${runtime?.ready ? 'badge--ok' : ''}">
          ${escapeHtml(runtime?.ready ? 'Ready' : runtime?.dockerCliPath ? 'Detected' : 'Missing')}
        </div>
      </div>

      <div class="runtime-grid">
        ${renderStatusCard('Docker CLI', runtime?.dockerCliPath ? 'Installed' : 'Not Detected', runtime?.dockerCliPath || 'Will be installed automatically when possible.')}
        ${renderStatusCard('Compose', runtime?.composeAvailable ? 'v2 Ready' : 'Missing', runtime?.composeProjectName || 'RoachNet project name will be assigned automatically.')}
        ${renderStatusCard('Daemon', runtime?.daemonRunning ? 'Running' : 'Stopped', runtime?.desktopCapable ? 'Desktop startup can be triggered from the wizard.' : 'Linux service mode will be used.')}
      </div>

      ${renderGuideCard(
        'A single runtime path, handled for the user',
        'The goal here is simple: detect Docker, install or update it when needed, and bring the RoachNet support stack online without making the user juggle terminals.',
        ['Detect installed Docker/Desktop', 'Install or update if required', 'Keep RoachNet-managed runtime data inside the install folder']
      )}

      <div class="action-strip">
        <button class="wizard-button wizard-button--primary" data-action="start-container-runtime" ${runtime?.ready ? 'disabled' : ''}>
          Start Container Runtime
        </button>
        <button class="wizard-button wizard-button--ghost" data-action="open-docker-docs">
          Docker Docs
        </button>
      </div>
    </section>
  `
}

function renderAiStep() {
  const config = getSetupConfig()

  return `
    <section class="wizard-panel">
      <div class="section-head">
        <div>
          <div class="hero-kicker">RoachClaw</div>
          <h2>Prepare the local AI stack</h2>
          <p class="section-copy">
            RoachClaw ships as RoachNet’s unified local AI bundle. The installer prepares Ollama,
            OpenClaw, and the default local model path together.
          </p>
        </div>
      </div>

      <div class="field-grid">
        <label class="field wide">
          <span>RoachClaw Default Model</span>
          <input type="text" name="roachClawDefaultModel" value="${escapeHtml(config.roachClawDefaultModel || 'qwen2.5-coder:7b')}" data-config-field />
        </label>
      </div>

      <div class="toggle-stack">
        ${renderToggle('autoInstallDependencies', 'Automatically install and update prerequisites', config.autoInstallDependencies)}
        ${renderToggle('installRoachClaw', 'Install and configure RoachClaw during setup', config.installRoachClaw !== false)}
        ${renderToggle('autoLaunch', 'Launch RoachNet when setup completes', config.autoLaunch)}
      </div>

      ${renderGuideCard(
        'One bundled AI path, not two separate installs',
        'When RoachClaw is enabled, the installer treats Ollama and OpenClaw as one setup track and prepares OpenClaw to use a local Ollama model by default.',
        ['Install the RoachClaw dependencies together', 'Save a default local model choice', 'Leave deeper tuning for the main app']
      )}
    </section>
  `
}

function renderToggle(name, title, checked) {
  return `
    <label class="toggle-row">
      <input type="checkbox" name="${escapeHtml(name)}" data-config-field ${checked ? 'checked' : ''} />
      <div>
        <strong>${escapeHtml(title)}</strong>
      </div>
    </label>
  `
}

function renderInstallStep() {
  const config = getSetupConfig()

  return `
    <section class="wizard-panel">
      <div class="section-head">
        <div>
          <div class="hero-kicker">Install</div>
          <h2>Target and release preferences</h2>
        </div>
      </div>

      <div class="field-grid">
        <label class="field wide">
          <span>Install Path</span>
          <input type="text" name="installPath" value="${escapeHtml(config.installPath || '')}" data-config-field />
        </label>
        <label class="field wide">
          <span>Desktop App Path</span>
          <input type="text" name="installedAppPath" value="${escapeHtml(config.installedAppPath || '')}" data-config-field />
        </label>
        <label class="field">
          <span>Source Mode</span>
          <select name="sourceMode" data-config-field>
            ${(state.setupState?.sourceModes || [])
              .map(
                (mode) =>
                  `<option value="${escapeHtml(mode.id)}"${config.sourceMode === mode.id ? ' selected' : ''}${mode.available === false ? ' disabled' : ''}>${escapeHtml(mode.label)}</option>`
              )
              .join('')}
          </select>
        </label>
        <label class="field">
          <span>Release Channel</span>
          <select name="releaseChannel" data-config-field>
            ${['stable', 'beta', 'alpha']
              .map(
                (channel) =>
                  `<option value="${channel}"${config.releaseChannel === channel ? ' selected' : ''}>${channel.toUpperCase()}</option>`
              )
              .join('')}
          </select>
        </label>
      </div>

      <div class="toggle-stack toggle-stack--compact">
        ${renderToggle('autoCheckUpdates', 'Check for updates automatically', config.autoCheckUpdates)}
        ${renderToggle('dryRun', 'Dry run only', config.dryRun)}
      </div>

      ${renderGuideCard(
        'Keep the first run simple',
        'Most users should only need the install destination and release channel. RoachNet keeps its app payload, runtime data, and managed content grouped inside the install folder by default.',
        ['Choose where RoachNet lives', 'Choose where the native app is installed', 'Run setup and hand off into the real app']
      )}

      <details class="details-card">
        <summary>Advanced install options</summary>
        <div class="field-grid">
          <label class="field wide">
            <span>Repository URL</span>
            <input type="text" name="sourceRepoUrl" value="${escapeHtml(config.sourceRepoUrl || '')}" data-config-field />
          </label>
          <label class="field">
            <span>Git Ref</span>
            <input type="text" name="sourceRef" value="${escapeHtml(config.sourceRef || '')}" data-config-field />
          </label>
          <label class="field">
            <span>Update Feed Override</span>
            <input type="text" name="updateBaseUrl" value="${escapeHtml(config.updateBaseUrl || '')}" data-config-field />
          </label>
        </div>

        <div class="toggle-stack toggle-stack--compact">
          ${renderToggle('launchAtLogin', 'Launch after OS login', config.launchAtLogin)}
        </div>
      </details>

      <div class="action-strip">
        <button class="wizard-button wizard-button--ghost" data-action="save-config">Save Profile</button>
        <button class="wizard-button wizard-button--primary" data-action="run-install">
          Run Setup
        </button>
      </div>
    </section>
  `
}

function renderFinishStep() {
  const task = getTask()
  const result = task?.result || {}

  return `
    <section class="wizard-panel finish-panel">
      <div class="finish-mark-shell">
        <div class="finish-ring finish-ring--outer"></div>
        <div class="finish-ring finish-ring--inner"></div>
        <img src="../assets/icon.png" alt="RoachNet" />
      </div>

      <div class="finish-copy">
        <div class="hero-kicker">Setup Complete</div>
        <h2>RoachNet is staged and ready.</h2>
        <p>
          Your install path, runtime configuration, and first-launch intro handoff have been prepared.
          The main app can now open straight into the real RoachNet experience.
        </p>
      </div>

      <div class="finish-metrics">
        ${renderStatusCard('Install Path', result.installPath || state.setupState?.installPath || 'Unknown', 'Persistent RoachNet workspace')}
        ${renderStatusCard('Desktop App', result.appPath || state.setupState?.nativeApp?.installPath || 'Unknown', 'The installer hands off to the native RoachNet app instead of reopening setup.')}
        ${renderStatusCard('Service URL', result.url || 'Native handoff', 'The intro reveal will play on the first main-app launch.')}
      </div>

      <div class="action-strip action-strip--center">
        <button class="wizard-button wizard-button--primary" data-action="launch-main-app">Launch RoachNet</button>
        <button class="wizard-button wizard-button--ghost" data-action="open-install-folder">Open Install Folder</button>
        <button class="wizard-button wizard-button--ghost" data-action="open-main-downloads">Main App Downloads</button>
      </div>
    </section>
  `
}

function renderLogPanel() {
  const task = getTask()
  const lines = Array.isArray(task?.logs) ? task.logs.slice(-18) : []

  return `
    <section class="wizard-panel wizard-log">
      <div class="section-head">
        <div>
          <div class="hero-kicker">Activity</div>
          <h2>Installer log</h2>
        </div>
        <div class="badge">${escapeHtml(task?.status || 'idle')}</div>
      </div>

      <div class="log-meta">
        ${task ? `Phase: ${escapeHtml(task.phase || 'Preparing')} | Started: ${escapeHtml(task.startedAt || 'Unknown')}` : 'No setup task has run yet.'}
        ${task?.error ? `<div class="log-error">${escapeHtml(task.error)}</div>` : ''}
      </div>
      <div class="log-stream">
        ${lines.length ? lines.map((line) => `<div class="log-line">${escapeHtml(line)}</div>`).join('') : '<div class="log-line">RoachNet Setup is ready. Continue through the wizard to begin.</div>'}
      </div>
    </section>
  `
}

function renderStepContent() {
  switch (getCurrentStep().id) {
    case 'welcome':
      return renderWelcomeStep()
    case 'machine':
      return renderMachineStep()
    case 'runtime':
      return renderRuntimeStep()
    case 'ai':
      return renderAiStep()
    case 'install':
      return renderInstallStep()
    case 'finish':
      return renderFinishStep()
    default:
      return renderWelcomeStep()
  }
}

function renderNavFooter() {
  const activeIndex = getVisibleStepIndex()
  const atFinish = getCurrentStep().id === 'finish'

  return `
    <div class="nav-footer">
      <button class="wizard-button wizard-button--ghost" data-action="prev-step" ${activeIndex === 0 || atFinish ? 'disabled' : ''}>Back</button>
      <button class="wizard-button wizard-button--secondary" data-action="refresh-state">Refresh</button>
      <button class="wizard-button wizard-button--primary" data-action="next-step" ${activeIndex >= steps.length - 2 || atFinish ? 'disabled' : ''}>Continue</button>
    </div>
  `
}

function render() {
  if (!state.setupState) {
    root.innerHTML = `
      ${renderWindowDragbar()}
      <section class="boot-screen">
        <div class="boot-mark">
          <div class="finish-ring finish-ring--outer"></div>
          <img src="../assets/icon.png" alt="RoachNet" />
        </div>
        <div class="boot-copy">
          <div class="hero-kicker">Booting</div>
          <h2>Preparing RoachNet Setup</h2>
          <p>Loading setup services and checking this machine.</p>
          ${state.error ? `<div class="error-banner">${escapeHtml(state.error)}</div>` : ''}
          <div class="action-strip action-strip--center">
            <button class="wizard-button wizard-button--secondary" data-action="refresh-state">
              Retry Connection
            </button>
          </div>
        </div>
      </section>
    `
    bindActions()
    return
  }

  root.innerHTML = `
    ${renderWindowDragbar()}
    <div class="wizard-shell">
      ${renderStepRail()}
      <section class="wizard-stage">
        <header class="stage-header">
          <div>
            <div class="hero-kicker">Step ${String(getVisibleStepIndex() + 1).padStart(2, '0')}</div>
            <h2>${escapeHtml(getCurrentStep().title)}</h2>
            <p>${escapeHtml(getCurrentStep().detail)}</p>
          </div>
          <div class="header-badges">
            <span class="badge">${escapeHtml(state.setupState.system?.osLabel || 'Unknown')}</span>
            <span class="badge">${escapeHtml(state.setupState.system?.arch || 'Unknown')}</span>
            <span class="badge">${escapeHtml(state.setupState.system?.packageManager?.label || 'Unknown')}</span>
          </div>
        </header>

        ${state.error ? `<div class="error-banner">${escapeHtml(state.error)}</div>` : ''}

        ${renderStepContent()}
        ${renderLogPanel()}
        ${renderNavFooter()}
      </section>
    </div>
  `

  bindActions()
}

async function withBusy(action, runner) {
  if (state.busyAction) {
    return
  }

  state.busyAction = action
  state.error = ''
  render()

  try {
    await runner()
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error)
  } finally {
    state.busyAction = ''
    await refreshState({ preserveDraft: true }).catch(() => {})
  }
}

function bindActions() {
  for (const field of root.querySelectorAll('[data-config-field]')) {
    field.addEventListener('input', () => {
      updateDraftFromForm()
    })
    field.addEventListener('change', () => {
      updateDraftFromForm()
    })
  }

  for (const stepButton of root.querySelectorAll('[data-step-index]')) {
    stepButton.addEventListener('click', () => {
      state.stepIndex = normalizeStepIndex(Number(stepButton.dataset.stepIndex))
      render()
    })
  }

  for (const button of root.querySelectorAll('[data-action]')) {
    if (state.busyAction) {
      button.disabled = true
    }

    button.addEventListener('click', async () => {
      const config = updateDraftFromForm()

      switch (button.dataset.action) {
        case 'next-step':
          state.stepIndex = normalizeStepIndex(getVisibleStepIndex() + 1)
          render()
          break
        case 'prev-step':
          state.stepIndex = normalizeStepIndex(getVisibleStepIndex() - 1)
          render()
          break
        case 'refresh-state':
          await withBusy('refresh-state', async () => {
            await refreshState({ preserveDraft: true })
          })
          break
        case 'save-config':
          await withBusy('save-config', async () => {
            await setup.saveConfig(config)
          })
          break
        case 'start-container-runtime':
          await withBusy('start-container-runtime', async () => {
            await setup.startContainerRuntime()
          })
          break
        case 'run-install':
          await withBusy('run-install', async () => {
            await setup.saveConfig(config)
            await setup.runInstall(config)
            state.stepIndex = steps.findIndex((step) => step.id === 'install')
          })
          break
        case 'launch-main-app':
          await withBusy('launch-main-app', async () => {
            await setup.launchMainApp()
          })
          break
        case 'open-docker-docs':
          await withBusy('open-docker-docs', async () => {
            await setup.openDockerDocs()
          })
          break
        case 'open-install-folder':
          await withBusy('open-install-folder', async () => {
            await setup.openInstallFolder()
          })
          break
        case 'open-main-downloads':
          await withBusy('open-main-downloads', async () => {
            await setup.openMainDownloads()
          })
          break
        default:
          break
      }
    })
  }
}

async function refreshState(options = {}) {
  if (!setup || typeof setup.getState !== 'function') {
    throw new Error(
      'The native setup bridge did not load correctly. Close RoachNet Setup and reopen it.'
    )
  }

  state.setupState = await setup.getState()
  if (!options.preserveDraft || !state.draftConfig) {
    syncDraft(true)
  }

  if (isInstallComplete() && !state.finishSequenceStarted) {
    state.finishSequenceStarted = true
    state.stepIndex = steps.findIndex((step) => step.id === 'finish')
  }

  render()
}

async function boot() {
  render()

  if (!refreshIntervalId) {
    refreshIntervalId = window.setInterval(() => {
      refreshState({ preserveDraft: true }).catch((error) => {
        state.error = error instanceof Error ? error.message : String(error)
        render()
      })
    }, 2500)
  }

  await refreshState()
}

window.addEventListener('beforeunload', () => {
  if (refreshIntervalId) {
    window.clearInterval(refreshIntervalId)
    refreshIntervalId = null
  }
})

boot().catch((error) => {
  state.error = error instanceof Error ? error.message : String(error)
  render()
})
