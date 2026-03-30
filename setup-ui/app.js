const form = document.querySelector('#setup-form')
const dependencyList = document.querySelector('#dependency-list')
const runtimeSummary = document.querySelector('#runtime-summary')
const systemGrid = document.querySelector('#system-grid')
const taskMeta = document.querySelector('#task-meta')
const logOutput = document.querySelector('#log-output')
const installButton = document.querySelector('#installButton')
const launchButton = document.querySelector('#launchButton')
const refreshButton = document.querySelector('#refreshButton')
const startRuntimeButton = document.querySelector('#startRuntimeButton')
const sourceModeSelect = document.querySelector('#sourceMode')
const repoUrlField = document.querySelector('#repo-url-field')

let hydrated = false
let saveTimer = null
let hasAutoNavigated = false

function collectConfig() {
  return {
    installPath: document.querySelector('#installPath').value.trim(),
    sourceMode: document.querySelector('#sourceMode').value,
    sourceRepoUrl: document.querySelector('#sourceRepoUrl').value.trim(),
    sourceRef: document.querySelector('#sourceRef').value.trim(),
    releaseChannel: document.querySelector('#releaseChannel').value,
    updateBaseUrl: document.querySelector('#updateBaseUrl').value.trim(),
    autoInstallDependencies: document.querySelector('#autoInstallDependencies').checked,
    installOptionalOllama: document.querySelector('#installOptionalOllama').checked,
    installOptionalOpenClaw: document.querySelector('#installOptionalOpenClaw').checked,
    autoLaunch: document.querySelector('#autoLaunch').checked,
    autoCheckUpdates: document.querySelector('#autoCheckUpdates').checked,
    launchAtLogin: document.querySelector('#launchAtLogin').checked,
    dryRun: document.querySelector('#dryRun').checked,
  }
}

function setButtonBusy(isBusy) {
  installButton.disabled = isBusy
  launchButton.disabled = isBusy
  installButton.textContent = isBusy ? 'Setup Running…' : 'Run Setup'
}

function renderSystem(state) {
  const cards = [
    ['Operating System', `${state.system.osLabel}`],
    ['Architecture', state.system.arch],
    ['Package Manager', state.system.packageManager.label],
    ['Recommended Profile', 'Portable Docker-backed setup'],
    ['Source Workspace', state.system.currentWorkspaceSourceAvailable ? 'Available' : 'Clone only'],
    ['Install Path', state.installPath],
  ]

  systemGrid.innerHTML = cards
    .map(
      ([label, value]) => `
        <div class="stat-card">
          <span class="status-label">${label}</span>
          <strong>${value}</strong>
        </div>
      `
    )
    .join('')
}

function renderDependencies(state) {
  dependencyList.innerHTML = state.dependencies
    .map((dependency) => {
      const statusLabel = dependency.needsUpdate
        ? 'Update'
        : dependency.available
          ? 'Ready'
          : dependency.required
            ? 'Missing'
            : 'Optional'
      const statusClass = dependency.available && !dependency.needsUpdate ? 'ok' : 'warn'
      const installCommand =
        (!dependency.available || dependency.needsUpdate) && dependency.installCommand
          ? `<div class="dependency-command">${dependency.installCommand}</div>`
          : ''
      const notes = dependency.notes ? `<div class="subtle">${dependency.notes}</div>` : ''
      const versionLine = dependency.version
        ? `<div class="subtle">Detected version: ${dependency.version}${dependency.minimumVersion ? ` | Required: ${dependency.minimumVersion}` : ''}</div>`
        : dependency.minimumVersion
          ? `<div class="subtle">Required version: ${dependency.minimumVersion}</div>`
          : ''

      return `
        <div class="dependency-item">
          <span class="dependency-state ${statusClass}">${statusLabel}</span>
          <strong>${dependency.label}</strong>
          <div class="subtle">${dependency.path || 'Not currently detected on this machine.'}</div>
          ${versionLine}
          ${installCommand}
          ${notes}
        </div>
      `
    })
    .join('')
}

function renderContainerRuntime(state) {
  const runtime = state.containerRuntime
  if (!runtime) {
    runtimeSummary.innerHTML = ''
    startRuntimeButton.disabled = true
    return
  }

  const runtimeStatus = runtime.ready
    ? 'Ready'
    : runtime.daemonRunning
      ? 'Compose Missing'
      : runtime.dockerCliPath
        ? 'Stopped'
        : 'Missing'

  runtimeSummary.innerHTML = `
    <div class="dependency-item">
      <span class="dependency-state ${runtime.ready ? 'ok' : 'warn'}">${runtimeStatus}</span>
      <strong>${runtime.integrationName}</strong>
      <div class="subtle">
        Docker CLI: ${runtime.dockerCliPath || 'Not detected'}<br />
        Compose: ${runtime.composeAvailable ? 'Docker Compose v2 ready' : 'Not available'}<br />
        Daemon: ${runtime.daemonRunning ? 'Running' : 'Stopped'}<br />
        Desktop: ${
          runtime.desktopCapable
            ? runtime.desktopCliAvailable
              ? runtime.desktopStatus
              : 'Desktop CLI unavailable'
            : 'Linux host service mode'
        }<br />
        Compose project: ${runtime.composeProjectName}
      </div>
      <div class="subtle">
        RoachNet will automatically detect, install, update, and start prerequisites when possible, then use the integrated container runtime to bring up support services.
      </div>
    </div>
  `

  startRuntimeButton.disabled = Boolean(runtime.ready)
}

function renderTask(state) {
  const task = state.activeTask || state.lastCompletedTask

  if (!task) {
    taskMeta.innerHTML = 'No setup has been run yet.'
    logOutput.textContent =
      'RoachNet Setup is ready.\n\nChoose an install path, review the detected dependencies, and press "Run Setup".'
    setButtonBusy(false)
    hasAutoNavigated = false
    return
  }

  const resultLink =
    task.result?.url
      ? `<a class="task-link" href="${task.result.url}" target="_blank" rel="noreferrer">${task.result.url}</a>`
      : 'Not launched yet'

  taskMeta.innerHTML = `
    <strong>Status:</strong> ${task.status} &nbsp;|&nbsp;
    <strong>Phase:</strong> ${task.phase} &nbsp;|&nbsp;
    <strong>Started:</strong> ${new Date(task.startedAt).toLocaleString()}
    ${task.finishedAt ? `&nbsp;|&nbsp;<strong>Finished:</strong> ${new Date(task.finishedAt).toLocaleString()}` : ''}
    ${task.result?.installPath ? `&nbsp;|&nbsp;<strong>Install Path:</strong> ${task.result.installPath}` : ''}
    ${task.result?.url ? `&nbsp;|&nbsp;<strong>RoachNet:</strong> ${resultLink}` : ''}
    ${task.error ? `<div class="subtle" style="margin-top:0.55rem;color:#ff9ab8;">${task.error}</div>` : ''}
  `

  logOutput.textContent = (task.logs || []).join('\n') || 'No logs yet.'
  setButtonBusy(task.status === 'running')

  if (
    task.status === 'completed' &&
    task.result?.url &&
    state.config.autoLaunch &&
    window.roachnetDesktop?.nativeShell &&
    !hasAutoNavigated
  ) {
    hasAutoNavigated = true
    setTimeout(() => {
      window.location.href = task.result.url
    }, 900)
  }
}

function renderSourceModes(state) {
  sourceModeSelect.innerHTML = state.sourceModes
    .filter((mode) => mode.available !== false || mode.id === 'clone')
    .map((mode) => `<option value="${mode.id}">${mode.label}</option>`)
    .join('')
}

function applyConfig(state) {
  if (hydrated) {
    return
  }

  renderSourceModes(state)
  document.querySelector('#installPath').value = state.config.installPath
  document.querySelector('#sourceMode').value = state.config.sourceMode
  document.querySelector('#sourceRepoUrl').value = state.config.sourceRepoUrl
  document.querySelector('#sourceRef').value = state.config.sourceRef
  document.querySelector('#releaseChannel').value = state.config.releaseChannel
  document.querySelector('#updateBaseUrl').value = state.config.updateBaseUrl || ''
  document.querySelector('#autoInstallDependencies').checked = state.config.autoInstallDependencies
  document.querySelector('#installOptionalOllama').checked = state.config.installOptionalOllama
  document.querySelector('#installOptionalOpenClaw').checked = state.config.installOptionalOpenClaw
  document.querySelector('#autoLaunch').checked = state.config.autoLaunch
  document.querySelector('#autoCheckUpdates').checked = state.config.autoCheckUpdates
  document.querySelector('#launchAtLogin').checked = state.config.launchAtLogin
  document.querySelector('#dryRun').checked = state.config.dryRun
  hydrated = true
  syncRepoFieldVisibility()
}

function syncRepoFieldVisibility() {
  repoUrlField.style.display = sourceModeSelect.value === 'clone' ? 'grid' : 'none'
}

async function fetchState() {
  const query = new URLSearchParams(collectConfig())
  const response = await fetch(`/api/state?${query.toString()}`, { cache: 'no-store' })
  const state = await response.json()
  applyConfig(state)
  renderSystem(state)
  renderContainerRuntime(state)
  renderDependencies(state)
  renderTask(state)
}

async function postJson(url, payload) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })

  const data = await response.json()
  if (!response.ok) {
    throw new Error(data.error || 'Request failed')
  }
  return data
}

async function persistConfig() {
  if (!hydrated) {
    return
  }

  await postJson('/api/config', collectConfig())
}

function schedulePersist() {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    persistConfig().catch(() => {})
  }, 250)
}

installButton.addEventListener('click', async () => {
  try {
    setButtonBusy(true)
    await postJson('/api/install', collectConfig())
    await fetchState()
  } catch (error) {
    alert(error.message)
    setButtonBusy(false)
  }
})

launchButton.addEventListener('click', async () => {
  try {
    await postJson('/api/launch', { installPath: document.querySelector('#installPath').value.trim() })
    await fetchState()
  } catch (error) {
    alert(error.message)
  }
})

refreshButton.addEventListener('click', () => {
  fetchState().catch((error) => {
    logOutput.textContent = `Failed to refresh installer state.\n${error.message}`
  })
})

startRuntimeButton.addEventListener('click', async () => {
  try {
    startRuntimeButton.disabled = true
    await postJson('/api/container-runtime/start', {})
    await fetchState()
  } catch (error) {
    alert(error.message)
  } finally {
    startRuntimeButton.disabled = false
  }
})

sourceModeSelect.addEventListener('change', syncRepoFieldVisibility)
form.addEventListener('input', () => {
  if (hydrated) {
    schedulePersist()
    fetchState().catch(() => {})
  }
})

fetchState().catch((error) => {
  logOutput.textContent = `Failed to load RoachNet Setup.\n${error.message}`
})

setInterval(() => {
  fetchState().catch(() => {})
}, 2500)
