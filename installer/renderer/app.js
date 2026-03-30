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

let lastRenderedMarkup = ''

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

function getNextStep() {
  return steps[Math.min(getVisibleStepIndex() + 1, steps.length - 1)]
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
  return `
    <section class="wizard-progress-shell">
      <div class="wizard-progress-head">
        <div class="rail-brand rail-brand--compact">
          <div class="rail-mark-shell">
            <img src="../../desktop/assets/icon.png" alt="RoachNet" />
          </div>
          <div>
            <div class="rail-kicker">RoachNet Setup</div>
            <h1>Install once, then move into RoachNet.</h1>
          </div>
        </div>
        <div class="wizard-progress-meta">Step ${getVisibleStepIndex() + 1} of ${steps.length}</div>
      </div>
      <div class="step-list step-list--row">
        ${steps
          .map((step, index) => {
            const status = getStepStatus(index)
            const active = status === 'active'
            return `
              <button class="step-chip step-chip--row step-chip--${status}" data-step-index="${index}">
                <span class="step-chip__index">${String(index + 1).padStart(2, '0')}</span>
                ${active ? `<span class="step-chip__copy"><strong>${escapeHtml(step.label)}</strong></span>` : ''}
              </button>
            `
          })
          .join('')}
      </div>
    </section>
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
    <section class="wizard-panel wizard-hero wizard-panel--focused">
      <div class="welcome-hero welcome-hero--compact">
        <div class="hero-copy">
          <div class="hero-kicker">RoachNet Installer</div>
          <h2>Set up RoachNet, RoachClaw, and the local runtime in one clean flow.</h2>
          <p>RoachNet Setup handles the machine check, runtime bootstrap, and first launch handoff for you.</p>
        </div>
        <div class="welcome-showcase welcome-showcase--compact">
          <article class="showcase-node showcase-node--active">
            <span>Contained</span>
            <strong>App, runtime, storage, and managed content stay grouped together.</strong>
          </article>
          <article class="showcase-node">
            <span>RoachClaw</span>
            <strong>Ollama and OpenClaw are prepared together with a local model-first default.</strong>
          </article>
          <article class="showcase-node">
            <span>Handoff</span>
            <strong>The main app opens only after setup is complete.</strong>
          </article>
        </div>
      </div>
      <div class="hero-grid hero-grid--compact">
        ${renderStatusCard('Flow', 'Guided Setup', 'One step at a time')}
        ${renderStatusCard('Runtime', 'Managed', 'Docker and support services')}
        ${renderStatusCard('AI', 'RoachClaw', 'Local model-first defaults')}
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
          <h2>Check this machine</h2>
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
        needsAttention.length ? 'RoachNet will finish the missing pieces' : 'This machine is already in good shape',
        needsAttention.length
          ? 'The remaining prerequisites can be installed or updated during setup.'
          : 'Most prerequisites are already available, so setup should stay quick.',
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
          <h2>Prepare the runtime</h2>
          <p class="section-copy">RoachNet can install, update, and start the container runtime for you.</p>
        </div>
        <div class="badge ${runtime?.ready ? 'badge--ok' : ''}">
          ${escapeHtml(runtime?.ready ? 'Ready' : runtime?.dockerCliPath ? 'Detected' : 'Missing')}
        </div>
      </div>

      <div class="runtime-grid">
        ${renderStatusCard('Docker CLI', runtime?.dockerCliPath ? 'Installed' : 'Not Detected', runtime?.dockerCliPath || 'Will be installed automatically when possible.')}
        ${renderStatusCard('Compose', runtime?.composeAvailable ? 'v2 Ready' : 'Missing', runtime?.composeProjectName || 'RoachNet project name will be assigned automatically.')}
        ${renderStatusCard('Daemon', runtime?.daemonRunning ? 'Running' : 'Stopped', runtime?.desktopCapable ? 'Desktop startup can be triggered from setup.' : 'Linux service mode will be used.')}
      </div>

      ${renderGuideCard(
        'One runtime path',
        'Detect Docker, install or update it when needed, and bring the RoachNet support stack online.',
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
          <h2>Prepare local AI</h2>
          <p class="section-copy">RoachClaw keeps Ollama and OpenClaw on one default path.</p>
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
        'One bundled AI path',
        'When RoachClaw is enabled, setup prepares Ollama and OpenClaw together and saves a local model-first default.',
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
          <h2>Choose where RoachNet lives</h2>
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
        'Most users only need the install destination and release channel. RoachNet keeps managed content grouped inside the install folder by default.',
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
        <button class="wizard-button wizard-button--ghost" data-action="save-config">Save Setup Profile</button>
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
        <img src="../../desktop/assets/icon.png" alt="RoachNet" />
      </div>

      <div class="finish-copy">
        <div class="hero-kicker">Setup Complete</div>
        <h2>RoachNet is ready.</h2>
        <p>The installer has finished. RoachNet can now open straight into the main app.</p>
      </div>

      <div class="finish-tour-preview">
        <article class="finish-tour-card">
          <span>First launch</span>
          <strong>Branded app reveal</strong>
          <small>The main app opens into a guided first look instead of raw setup screens.</small>
        </article>
        <article class="finish-tour-card">
          <span>RoachClaw</span>
          <strong>Local AI ready path</strong>
          <small>RoachClaw starts from a local model-first default.</small>
        </article>
        <article class="finish-tour-card">
          <span>Workspace</span>
          <strong>Native command center</strong>
          <small>Runtime, models, chat, and local tools now live in one shell.</small>
        </article>
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
          <h2>Live status</h2>
        </div>
        <div class="badge">${escapeHtml(task?.status || 'idle')}</div>
      </div>

      <div class="log-meta">
        ${task ? `Phase: ${escapeHtml(task.phase || 'Preparing')} | Started: ${escapeHtml(task.startedAt || 'Unknown')}` : 'No setup task has run yet.'}
        ${task?.error ? `<div class="log-error">${escapeHtml(task.error)}</div>` : ''}
      </div>
      <div class="log-stream">
        ${lines.length ? lines.map((line) => `<div class="log-line">${escapeHtml(line)}</div>`).join('') : '<div class="log-line">RoachNet Setup is ready. Continue through the flow to begin installation.</div>'}
      </div>
    </section>
  `
}

function shouldShowLogPanel() {
  const task = getTask()
  return Boolean(state.error || task?.status === 'running' || task?.status === 'failed')
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

function renderJourneyBanner() {
  const currentStep = getCurrentStep()

  return `
    <section class="journey-banner">
      <div class="journey-banner__copy">
        <div class="hero-kicker">Current Step</div>
        <h3>${escapeHtml(currentStep.title)}</h3>
      </div>
    </section>
  `
}

function renderNavFooter() {
  const activeIndex = getVisibleStepIndex()
  const atFinish = getCurrentStep().id === 'finish'

  return `
    <div class="nav-footer">
      <button class="wizard-button wizard-button--ghost" data-action="prev-step" ${activeIndex === 0 || atFinish ? 'disabled' : ''}>Back</button>
      <div class="nav-footer__spacer"></div>
      <button class="wizard-button wizard-button--secondary" data-action="refresh-state">Refresh</button>
      <button class="wizard-button wizard-button--primary" data-action="next-step" ${activeIndex >= steps.length - 2 || atFinish ? 'disabled' : ''}>Continue</button>
    </div>
  `
}

function render() {
  let markup = ''

  if (!state.setupState) {
    markup = `
      ${renderWindowDragbar()}
      <section class="boot-screen">
        <div class="boot-mark">
          <div class="finish-ring finish-ring--outer"></div>
          <img src="../../desktop/assets/icon.png" alt="RoachNet" />
        </div>
        <div class="boot-copy">
          <div class="hero-kicker">Booting</div>
          <h2>Preparing RoachNet Setup</h2>
          <p>Loading the native installer, checking this machine, and preparing the guided setup flow.</p>
          ${state.error ? `<div class="error-banner">${escapeHtml(state.error)}</div>` : ''}
          <div class="action-strip action-strip--center">
            <button class="wizard-button wizard-button--secondary" data-action="refresh-state">
              Retry Connection
            </button>
          </div>
        </div>
      </section>
    `
  } else {
    markup = `
      ${renderWindowDragbar()}
      <div class="wizard-shell">
        ${renderStepRail()}
        <section class="wizard-stage">
          <header class="stage-header">
            <div>
              <div class="hero-kicker">Step ${String(getVisibleStepIndex() + 1).padStart(2, '0')}</div>
              <h2>${escapeHtml(getCurrentStep().title)}</h2>
            </div>
            <div class="header-badges">
              <span class="badge">${escapeHtml(state.setupState.system?.osLabel || 'Unknown')}</span>
            </div>
          </header>

          ${state.error ? `<div class="error-banner">${escapeHtml(state.error)}</div>` : ''}

          ${renderStepContent()}
          ${shouldShowLogPanel() ? renderLogPanel() : ''}
          ${renderNavFooter()}
        </section>
      </div>
    `
  }

  if (markup === lastRenderedMarkup) {
    return
  }

  lastRenderedMarkup = markup
  root.innerHTML = markup
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
      const active = document.activeElement
      if (active?.matches?.('[data-config-field], input, select, textarea')) {
        return
      }

      refreshState({ preserveDraft: true }).catch((error) => {
        state.error = error instanceof Error ? error.message : String(error)
        render()
      })
    }, 5000)
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
