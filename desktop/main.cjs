const { app, BrowserWindow, Menu, dialog, ipcMain, nativeImage, shell } = require('electron')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const fsp = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const {
  RELEASE_CHANNELS,
  getConfigPath,
  readConfig,
  writeConfig,
} = require('./config.cjs')
const { createUpdaterController } = require('./updater.cjs')

const serverInfoPath = path.join(os.tmpdir(), 'roachnet-desktop-server.json')
const setupUrlRegex = /RoachNet Setup is available at (http:\/\/\S+)/i
const appUrlRegex = /(RoachNet is already running at|Web UI:)\s+(http:\/\/\S+)/i
const releasesUrl = 'https://github.com/AHGRoach/RoachNet/releases'
const mlxDocsUrl = 'https://ml-explore.github.io/mlx/build/html/index.html'
const exoRepoUrl = 'https://github.com/exo-explore/exo'
const HEALTH_TIMEOUT_MS = 3_500
const PROBE_TIMEOUT_MS = 4_000

let mainWindow = null
let managedProcess = null
let managedServerPid = null
let updaterController = null
let runtimeMode = null
let runtimeUrl = null
let runtimeInfo = null
let runtimeLastError = null
let diagnosticLogPath = null

function resolveDiagnosticLogPath() {
  if (diagnosticLogPath) {
    return diagnosticLogPath
  }

  const baseDir =
    typeof app.isReady === 'function' && app.isReady()
      ? app.getPath('userData')
      : path.join(os.tmpdir(), 'roachnet')

  diagnosticLogPath = path.join(baseDir, 'native-shell.log')
  return diagnosticLogPath
}

function formatDiagnosticMeta(meta) {
  if (meta === undefined) {
    return ''
  }

  try {
    return ` ${JSON.stringify(meta)}`
  } catch (error) {
    return ` ${String(meta)}`
  }
}

function formatErrorForDiagnostics(error) {
  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message,
      stack: error.stack || null,
    }
  }

  return {
    message: String(error),
  }
}

function writeDiagnosticLog(message, meta) {
  try {
    const logPath = resolveDiagnosticLogPath()
    fs.mkdirSync(path.dirname(logPath), { recursive: true })
    fs.appendFileSync(
      logPath,
      `[${new Date().toISOString()}] ${message}${formatDiagnosticMeta(meta)}\n`,
      'utf8'
    )
  } catch {
    // Best-effort logging only.
  }
}

process.on('uncaughtException', (error) => {
  writeDiagnosticLog('uncaughtException', formatErrorForDiagnostics(error))
})

process.on('unhandledRejection', (reason) => {
  writeDiagnosticLog('unhandledRejection', formatErrorForDiagnostics(reason))
})

const hasSingleInstanceLock = app.requestSingleInstanceLock()
if (!hasSingleInstanceLock) {
  writeDiagnosticLog('app:single-instance-lock-denied')
  app.quit()
}

function getDesktopAssetRoot() {
  return __dirname
}

function getBundledWorkspaceRoot() {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, 'app.asar.unpacked')
  }

  return path.resolve(__dirname, '..')
}

function getRendererEntryPath() {
  return path.join(getDesktopAssetRoot(), 'renderer', 'index.html')
}

function getInstallerConfig() {
  return readConfig(app)
}

function saveInstallerConfig(updates) {
  const nextConfig = writeConfig(app, updates)
  applyDesktopPreferences(nextConfig)
  buildAppMenu()
  return nextConfig
}

function getNodeRunnerEnv() {
  return {
    ...process.env,
    ELECTRON_RUN_AS_NODE: '1',
    ROACHNET_NO_BROWSER: '1',
    ROACHNET_SETUP_NO_BROWSER: '1',
    ROACHNET_INSTALLER_CONFIG_PATH: getConfigPath(app),
  }
}

function getInstalledRepoRoot(config = getInstallerConfig()) {
  if (!config?.installPath) {
    return null
  }

  const installPath = path.resolve(config.installPath)
  if (
    fs.existsSync(path.join(installPath, 'scripts', 'run-roachnet.mjs')) &&
    fs.existsSync(path.join(installPath, 'admin', 'package.json'))
  ) {
    return installPath
  }

  return null
}

function getInstallerHelperCandidates() {
  const candidates = new Set()
  const repoRoot = path.resolve(__dirname, '..')

  if (process.env.ROACHNET_SETUP_APP_PATH) {
    candidates.add(path.resolve(process.env.ROACHNET_SETUP_APP_PATH))
  }

  if (app.isPackaged) {
    const currentBundlePath =
      process.platform === 'darwin'
        ? path.resolve(app.getPath('exe'), '..', '..', '..')
        : path.dirname(app.getPath('exe'))
    const distDir = path.dirname(currentBundlePath)

    if (process.platform === 'darwin') {
      candidates.add(path.join(distDir, 'RoachNet Setup.app'))
    } else if (process.platform === 'win32') {
      candidates.add(path.join(distDir, 'RoachNet Setup.exe'))
    } else {
      candidates.add(path.join(distDir, 'RoachNet Setup.AppImage'))
      candidates.add(path.join(distDir, 'RoachNet Setup'))
    }
  } else {
    if (process.platform === 'darwin') {
      candidates.add(path.join(repoRoot, 'setup-dist', 'mac-arm64', 'RoachNet Setup.app'))
    } else if (process.platform === 'win32') {
      candidates.add(path.join(repoRoot, 'setup-dist', 'win-unpacked', 'RoachNet Setup.exe'))
    } else {
      candidates.add(path.join(repoRoot, 'setup-dist', 'linux-unpacked', 'RoachNet Setup'))
      candidates.add(path.join(repoRoot, 'setup-dist', 'RoachNet Setup.AppImage'))
    }
  }

  return [...candidates].filter(Boolean)
}

async function openInstallerHelper() {
  const installerPath = getInstallerHelperCandidates().find((candidate) => fs.existsSync(candidate))

  if (installerPath) {
    const shellError = await shell.openPath(installerPath)
    if (shellError) {
      throw new Error(shellError)
    }

    return {
      ok: true,
      launched: 'installer-app',
      path: installerPath,
    }
  }

  await shell.openExternal(releasesUrl)
  return {
    ok: true,
    launched: 'release-downloads',
    path: null,
  }
}

function createMainWindow() {
  const iconPath = path.join(getDesktopAssetRoot(), 'assets', 'icon.png')
  const icon = fs.existsSync(iconPath) ? nativeImage.createFromPath(iconPath) : undefined
  writeDiagnosticLog('createMainWindow:start', {
    iconPath,
    iconExists: fs.existsSync(iconPath),
    preload: path.join(getDesktopAssetRoot(), 'preload.cjs'),
    renderer: getRendererEntryPath(),
  })

  const window = new BrowserWindow({
    width: 1540,
    height: 1020,
    minWidth: 1180,
    minHeight: 760,
    resizable: true,
    movable: true,
    maximizable: true,
    fullscreenable: true,
    backgroundColor: '#050b08',
    autoHideMenuBar: false,
    show: false,
    title: 'RoachNet',
    icon,
    titleBarStyle: process.platform === 'darwin' ? 'hidden' : 'default',
    trafficLightPosition: process.platform === 'darwin' ? { x: 18, y: 18 } : undefined,
    webPreferences: {
      preload: path.join(getDesktopAssetRoot(), 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  })

  window.webContents.setWindowOpenHandler(({ url }) => {
    writeDiagnosticLog('windowOpenHandler:external', { url })
    shell.openExternal(url)
    return { action: 'deny' }
  })

  window.webContents.on('will-navigate', (event, url) => {
    if (url.startsWith('file://')) {
      return
    }

    event.preventDefault()
    writeDiagnosticLog('will-navigate:external', { url })
    shell.openExternal(url)
  })

  window.once('ready-to-show', () => {
    writeDiagnosticLog('mainWindow:ready-to-show')
    window.show()
  })

  window.webContents.on('did-finish-load', () => {
    writeDiagnosticLog('mainWindow:did-finish-load', {
      url: window.webContents.getURL(),
    })

    if (!window.isVisible()) {
      window.show()
    }
  })

  window.webContents.on(
    'did-fail-load',
    (_event, errorCode, errorDescription, validatedURL, isMainFrame) => {
      writeDiagnosticLog('mainWindow:did-fail-load', {
        errorCode,
        errorDescription,
        validatedURL,
        isMainFrame,
      })
    }
  )

  window.webContents.on('render-process-gone', (_event, details) => {
    writeDiagnosticLog('mainWindow:render-process-gone', details)
  })

  window.webContents.on('unresponsive', () => {
    writeDiagnosticLog('mainWindow:webContents-unresponsive')
  })

  window.webContents.on('console-message', (_event, level, message, line, sourceId) => {
    if (level >= 2) {
      writeDiagnosticLog('renderer:console-message', {
        level,
        message,
        line,
        sourceId,
      })
    }
  })

  window.on('show', () => {
    writeDiagnosticLog('mainWindow:show')
  })

  window.on('unresponsive', () => {
    writeDiagnosticLog('mainWindow:unresponsive')
  })

  window.on('closed', () => {
    writeDiagnosticLog('mainWindow:closed')
    mainWindow = null
  })

  writeDiagnosticLog('createMainWindow:complete')
  return window
}

async function readServerInfo() {
  if (!fs.existsSync(serverInfoPath)) {
    return null
  }

  try {
    return JSON.parse(await fsp.readFile(serverInfoPath, 'utf8'))
  } catch {
    return null
  }
}

function clearRuntimeState() {
  runtimeMode = null
  runtimeUrl = null
  runtimeInfo = null
  writeDiagnosticLog('runtime:cleared')
}

async function sendStateUpdate() {
  if (!mainWindow || mainWindow.isDestroyed()) {
    return
  }

  try {
    mainWindow.webContents.send('roachnet:state', await getDesktopState())
  } catch {
    // Renderer may not be ready yet.
  }
}

function stopManagedProcess() {
  writeDiagnosticLog('runtime:stopManagedProcess:start', {
    hasManagedProcess: Boolean(managedProcess),
    managedServerPid,
  })
  if (managedProcess && !managedProcess.killed) {
    managedProcess.kill('SIGTERM')
  }

  if (managedServerPid) {
    try {
      process.kill(managedServerPid, 'SIGTERM')
    } catch {}
  }

  managedProcess = null
  managedServerPid = null
  clearRuntimeState()
  writeDiagnosticLog('runtime:stopManagedProcess:complete')
}

function spawnManagedNode(scriptPath, cwd, extraEnv, urlRegex) {
  return new Promise((resolve, reject) => {
    writeDiagnosticLog('runtime:spawnManagedNode:start', {
      scriptPath,
      cwd,
      extraEnvKeys: Object.keys(extraEnv || {}),
    })
    const child = spawn(process.execPath, [scriptPath], {
      cwd,
      env: {
        ...getNodeRunnerEnv(),
        ...extraEnv,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    managedProcess = child
    let settled = false
    let output = ''

    const maybeResolveFromOutput = async (text) => {
      output += text
      const match = text.match(urlRegex) || output.match(urlRegex)

      if (!match || settled) {
        return
      }

      settled = true
      const info = await readServerInfo()
      managedServerPid = info?.pid ?? null
      writeDiagnosticLog('runtime:spawnManagedNode:resolved', {
        scriptPath,
        url: match[match.length - 1],
        managedServerPid,
      })
      resolve({
        child,
        url: match[match.length - 1],
        info,
      })
    }

    child.stdout.on('data', (chunk) => {
      maybeResolveFromOutput(chunk.toString()).catch(reject)
    })

    child.stderr.on('data', (chunk) => {
      output += chunk.toString()
    })

    child.on('error', (error) => {
      writeDiagnosticLog('runtime:spawnManagedNode:error', {
        scriptPath,
        error: formatErrorForDiagnostics(error),
      })
      if (!settled) {
        settled = true
        reject(error)
      }
    })

    child.on('exit', (code) => {
      writeDiagnosticLog('runtime:spawnManagedNode:exit', {
        scriptPath,
        code,
        output: output.trim().slice(-4000),
      })
      if (managedProcess === child) {
        managedProcess = null
        managedServerPid = null
        clearRuntimeState()
        sendStateUpdate().catch(() => {})
      }

      if (!settled) {
        settled = true
        reject(new Error(output.trim() || `${path.basename(scriptPath)} exited with code ${code}`))
      }
    })
  })
}

async function fetchJson(url, options = {}) {
  const abortController = new AbortController()
  const timeout = setTimeout(() => abortController.abort(), options.timeoutMs || HEALTH_TIMEOUT_MS)

  try {
    const isJsonBody =
      options.body !== undefined &&
      !(typeof FormData !== 'undefined' && options.body instanceof FormData)

    const response = await fetch(url, {
      method: options.method || 'GET',
      headers: {
        Accept: 'application/json',
        ...(isJsonBody ? { 'Content-Type': 'application/json' } : {}),
        ...(options.headers || {}),
      },
      body:
        options.body === undefined
          ? undefined
          : isJsonBody
            ? JSON.stringify(options.body)
            : options.body,
      signal: abortController.signal,
    })

    const payload = await response.json().catch(() => null)
    if (!response.ok) {
      throw new Error(payload?.error || `${response.status} ${response.statusText}`)
    }

    return payload
  } finally {
    clearTimeout(timeout)
  }
}

function getShellCommand(binary) {
  return process.platform === 'win32' ? `${binary}.exe` : binary
}

async function runProbeCommand(binary, args = [], options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, args, {
      cwd: options.cwd || process.cwd(),
      env: options.env || process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    let stdout = ''
    let stderr = ''
    let settled = false
    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true
        child.kill('SIGTERM')
        reject(new Error(`${binary} probe timed out after ${options.timeoutMs || PROBE_TIMEOUT_MS}ms`))
      }
    }, options.timeoutMs || PROBE_TIMEOUT_MS)

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString()
    })

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString()
    })

    child.on('error', (error) => {
      if (!settled) {
        settled = true
        clearTimeout(timeout)
        reject(error)
      }
    })

    child.on('close', (code) => {
      if (settled) {
        return
      }

      settled = true
      clearTimeout(timeout)

      if (code === 0) {
        resolve({
          stdout: stdout.trim(),
          stderr: stderr.trim(),
        })
        return
      }

      reject(new Error(stderr.trim() || stdout.trim() || `${binary} exited with code ${code}`))
    })
  })
}

async function probePythonModule(moduleName, versionExpression = '__version__') {
  const pythonCandidates =
    process.platform === 'win32'
      ? [['py', ['-3']], ['python', []], ['python3', []]]
      : [['python3', []], ['python', []]]

  for (const [binary, prefixArgs] of pythonCandidates) {
    try {
      const result = await runProbeCommand(
        binary,
        [
          ...prefixArgs,
          '-c',
          `import ${moduleName}; value=getattr(${moduleName}, "${versionExpression}", None); print(value or "installed")`,
        ],
        { timeoutMs: PROBE_TIMEOUT_MS }
      )

      return {
        installed: true,
        binary,
        version: result.stdout || 'installed',
        error: null,
      }
    } catch (error) {
      // Probe the next Python binary.
    }
  }

  return {
    installed: false,
    binary: null,
    version: null,
    error: `Python module "${moduleName}" is not available in the detected Python runtimes.`,
  }
}

async function probeHttpStatus(baseUrl, paths) {
  for (const candidatePath of paths) {
    try {
      const url = new URL(candidatePath, baseUrl).toString()
      const abortController = new AbortController()
      const timeout = setTimeout(() => abortController.abort(), PROBE_TIMEOUT_MS)
      const response = await fetch(url, {
        headers: { Accept: 'application/json, text/plain, */*' },
        signal: abortController.signal,
      }).finally(() => clearTimeout(timeout))

      if (response.ok || (response.status >= 200 && response.status < 500 && response.status !== 404)) {
        return {
          reachable: true,
          path: candidatePath,
          status: response.status,
          error: null,
        }
      }
    } catch (error) {
      // Try the next endpoint.
    }
  }

  return {
    reachable: false,
    path: null,
    status: null,
    error: `No reachable endpoint responded at ${baseUrl}.`,
  }
}

async function getAccelerationState(config, desktopState) {
  const systemInfo = desktopState?.aiWorkbench?.systemInfo?.data
  const hardware = systemInfo?.hardwareProfile || null
  const isAppleSilicon =
    process.platform === 'darwin' && (hardware?.isAppleSilicon || process.arch === 'arm64')

  const mlxCore = isAppleSilicon ? await probePythonModule('mlx') : null
  const mlxLm = isAppleSilicon ? await probePythonModule('mlx_lm') : null
  const mlxServerProbe =
    isAppleSilicon && config.mlxBaseUrl
      ? await probeHttpStatus(config.mlxBaseUrl, ['/v1/models', '/'])
      : {
          reachable: false,
          path: null,
          status: null,
          error: null,
        }

  const exoProbe =
    config.distributedInferenceBackend === 'exo'
      ? await probeHttpStatus(config.exoBaseUrl, ['/', '/v1/models', '/api/tags'])
      : {
          reachable: false,
          path: null,
          status: null,
          error: null,
        }

  const recommendations = []

  if (isAppleSilicon) {
    recommendations.push(
      'Apple Silicon is the best RoachNet target for MLX-backed local inference because MLX is designed for efficient machine learning on Apple silicon.'
    )
  }

  if (hardware?.recommendedRuntime === 'native_local') {
    recommendations.push(
      'Keep local AI runtimes host-native for the best memory and latency profile on this machine.'
    )
  }

  if (config.appleAccelerationBackend === 'mlx' && !mlxCore?.installed) {
    recommendations.push(
      'MLX mode is selected, but the MLX Python runtime is not installed yet. Install MLX and mlx-lm before enabling MLX-backed local inference.'
    )
  }

  if (config.appleAccelerationBackend === 'mlx' && mlxCore?.installed && !mlxServerProbe.reachable) {
    recommendations.push(
      'MLX is selected, but no reachable local MLX server endpoint was detected. RoachNet will fall back to Ollama until an MLX-compatible local server is running.'
    )
  }

  if (config.distributedInferenceBackend === 'disabled') {
    recommendations.push(
      'Distributed inference is disabled, so RoachNet stays on the single-machine path and avoids exo cluster overhead.'
    )
  }

  if (config.distributedInferenceBackend === 'exo') {
    recommendations.push(
      'exo is enabled, but it should only be used when you actually want multi-device execution. Keep it disabled for the best single-machine latency and token efficiency.'
    )
  }

  return {
    apple: {
      supported: isAppleSilicon,
      preferredBackend: config.appleAccelerationBackend,
      installOptionalMlx: Boolean(config.installOptionalMlx),
      baseUrl: config.mlxBaseUrl,
      modelId: config.mlxModelId || null,
      mlx: mlxCore
        ? {
            installed: mlxCore.installed,
            version: mlxCore.version,
            python: mlxCore.binary,
            error: mlxCore.error,
          }
        : null,
      mlxLm: mlxLm
        ? {
            installed: mlxLm.installed,
            version: mlxLm.version,
            python: mlxLm.binary,
            error: mlxLm.error,
          }
        : null,
      server: {
        reachable: mlxServerProbe.reachable,
        path: mlxServerProbe.path,
        status: mlxServerProbe.status,
        error: mlxServerProbe.error,
      },
    },
    distributed: {
      backend: config.distributedInferenceBackend,
      exo: {
        enabled: config.distributedInferenceBackend === 'exo',
        baseUrl: config.exoBaseUrl,
        nodeRole: config.exoNodeRole,
        autoStart: Boolean(config.exoAutoStart),
        reachable: exoProbe.reachable,
        path: exoProbe.path,
        status: exoProbe.status,
        error: exoProbe.error,
      },
    },
    recommendations,
    docs: {
      mlx: mlxDocsUrl,
      exo: exoRepoUrl,
    },
  }
}

async function callOpenAICompatibleChat(baseUrl, payload, timeoutMs = 120_000) {
  const apiUrl = new URL('/v1/chat/completions', baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`)
  return fetchJson(apiUrl.toString(), {
    method: 'POST',
    body: payload,
    timeoutMs,
  })
}

function getOpenAICompatibleMessageContent(response) {
  const content = response?.choices?.[0]?.message?.content
  if (typeof content === 'string') {
    return content
  }

  if (Array.isArray(content)) {
    return content
      .map((item) => {
        if (typeof item === 'string') {
          return item
        }

        if (item?.type === 'text' && typeof item.text === 'string') {
          return item.text
        }

        return ''
      })
      .join('\n')
      .trim()
  }

  return ''
}

async function appendSessionMessage(sessionId, role, content) {
  return callManagedAppApi(`/api/chat/sessions/${sessionId}/messages`, {
    method: 'POST',
    body: {
      role,
      content,
    },
    timeoutMs: 20_000,
  })
}

async function updateSessionModel(sessionId, title, model) {
  return callManagedAppApi(`/api/chat/sessions/${sessionId}`, {
    method: 'PUT',
    body: {
      title,
      model,
    },
    timeoutMs: 20_000,
  })
}

async function resolveChatExecutionRoute() {
  const config = getInstallerConfig()
  const managedSystemInfo = await getManagedSystemInfoIfAvailable()
  const acceleration = await getAccelerationState(config, {
    aiWorkbench: {
      systemInfo: {
        ok: Boolean(managedSystemInfo),
        data: managedSystemInfo,
      },
    },
  })

  if (
    config.distributedInferenceBackend === 'exo' &&
    acceleration.distributed?.exo?.reachable
  ) {
    return {
      route: 'exo',
      baseUrl: config.exoBaseUrl,
      model: config.exoModelId || null,
      acceleration,
    }
  }

  if (
    config.appleAccelerationBackend === 'mlx' &&
    acceleration.apple?.supported &&
    acceleration.apple?.server?.reachable
  ) {
    return {
      route: 'mlx',
      baseUrl: config.mlxBaseUrl,
      model: config.mlxModelId || null,
      acceleration,
    }
  }

  return {
    route: 'ollama',
    baseUrl: null,
    model: null,
    acceleration,
  }
}

async function uploadFileToManagedApp(filePath) {
  const runtime = await ensureManagedMode('app')
  const url = new URL('/api/rag/upload', runtime.url)
  const fileBuffer = await fsp.readFile(filePath)
  const form = new FormData()
  form.set('file', new Blob([fileBuffer]), path.basename(filePath))

  return fetchJson(url.toString(), {
    method: 'POST',
    body: form,
    timeoutMs: 120_000,
  })
}

async function getManagedSetupState() {
  if (runtimeMode !== 'setup' || !runtimeUrl) {
    return null
  }

  try {
    return await fetchJson(new URL('/api/state', runtimeUrl).toString(), {
      timeoutMs: 5_000,
    })
  } catch (error) {
    runtimeLastError = error instanceof Error ? error.message : String(error)
    return null
  }
}

async function getManagedAppHealth() {
  if (runtimeMode !== 'app' || !runtimeUrl) {
    return null
  }

  try {
    const payload = await fetchJson(new URL('/api/health', runtimeUrl).toString())
    return {
      ok: true,
      payload,
    }
  } catch (error) {
    runtimeLastError = error instanceof Error ? error.message : String(error)
    return {
      ok: false,
      error: runtimeLastError,
    }
  }
}

async function getManagedSystemInfoIfAvailable() {
  if (runtimeMode !== 'app' || !runtimeUrl) {
    return null
  }

  try {
    return await callManagedAppApi('/api/system/info')
  } catch {
    return null
  }
}

function addQueryParams(url, query = {}) {
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null || value === '') {
      continue
    }

    url.searchParams.set(key, String(value))
  }
}

async function callManagedAppApi(pathname, options = {}) {
  const runtime = await ensureManagedMode('app')
  const url = new URL(pathname, runtime.url)
  addQueryParams(url, options.query)

  return fetchJson(url.toString(), {
    method: options.method,
    body: options.body,
    timeoutMs: options.timeoutMs || 15_000,
  })
}

function getSettledPayload(result) {
  if (result.status === 'fulfilled') {
    return {
      ok: true,
      data: result.value,
      error: null,
    }
  }

  return {
    ok: false,
    data: null,
    error: result.reason instanceof Error ? result.reason.message : String(result.reason),
  }
}

async function getAIWorkbenchState() {
  const results = await Promise.allSettled([
    callManagedAppApi('/api/system/info'),
    callManagedAppApi('/api/system/ai/providers'),
    callManagedAppApi('/api/roachclaw/status'),
    callManagedAppApi('/api/ollama/installed-models'),
    callManagedAppApi('/api/openclaw/skills/status'),
    callManagedAppApi('/api/openclaw/skills/installed'),
    callManagedAppApi('/api/chat/sessions'),
    callManagedAppApi('/api/chat/suggestions'),
  ])

  const [
    systemInfo,
    providers,
    roachclaw,
    installedModels,
    skillCliStatus,
    installedSkills,
    chatSessions,
    chatSuggestions,
  ] = results.map(getSettledPayload)

  return {
    systemInfo,
    providers,
    roachclaw,
    installedModels,
    skillCliStatus,
    installedSkills,
    chatSessions,
    chatSuggestions,
  }
}

async function getKnowledgeWorkbenchState() {
  const [files, activeJobs] = await Promise.allSettled([
    callManagedAppApi('/api/rag/files'),
    callManagedAppApi('/api/rag/active-jobs'),
  ])

  return {
    files: getSettledPayload(files),
    activeJobs: getSettledPayload(activeJobs),
  }
}

function getDesiredAutoMode(config = getInstallerConfig()) {
  const installedRoot = getInstalledRepoRoot(config)
  if (installedRoot && config.setupCompletedAt) {
    return 'app'
  }

  return 'idle'
}

async function ensureManagedMode(mode = 'auto') {
  const desktopConfig = getInstallerConfig()
  const bundledRoot = getBundledWorkspaceRoot()
  const desiredMode = mode === 'auto' ? getDesiredAutoMode(desktopConfig) : mode
  const installedRoot = getInstalledRepoRoot(desktopConfig)
  writeDiagnosticLog('runtime:ensureManagedMode:start', {
    requestedMode: mode,
    desiredMode,
    installedRoot,
    bundledRoot,
  })

  if (desiredMode === 'app' && !installedRoot) {
    throw new Error('No installed RoachNet workspace was found yet. Run the setup flow first.')
  }

  if (desiredMode === 'idle') {
    stopManagedProcess()
    runtimeLastError = null
    await sendStateUpdate()
    return {
      mode: runtimeMode,
      url: runtimeUrl,
      info: runtimeInfo,
    }
  }

  if (managedProcess && !managedProcess.killed && runtimeMode === desiredMode && runtimeUrl) {
    writeDiagnosticLog('runtime:ensureManagedMode:reuse', {
      desiredMode,
      runtimeUrl,
    })
    return {
      mode: runtimeMode,
      url: runtimeUrl,
      info: runtimeInfo,
    }
  }

  stopManagedProcess()
  runtimeLastError = null
  await fsp.rm(serverInfoPath, { force: true }).catch(() => {})

  if (desiredMode === 'app') {
    const scriptPath = path.join(installedRoot, 'scripts', 'run-roachnet.mjs')
    const result = await spawnManagedNode(
      scriptPath,
      installedRoot,
      {
        ROACHNET_SERVER_INFO_FILE: serverInfoPath,
      },
      appUrlRegex
    )

    runtimeMode = 'app'
    runtimeUrl = result.url
    runtimeInfo = result.info || null
    writeDiagnosticLog('runtime:ensureManagedMode:app-ready', {
      runtimeUrl,
      managedServerPid,
    })

    saveInstallerConfig({
      installPath: installedRoot,
      lastLaunchUrl: result.url,
      lastOpenedMode: 'app',
      setupCompletedAt: desktopConfig.setupCompletedAt || new Date().toISOString(),
    })
    await sendStateUpdate()
    return {
      mode: runtimeMode,
      url: runtimeUrl,
      info: runtimeInfo,
    }
  }

  if (desiredMode === 'setup' && app.isPackaged) {
    await openInstallerHelper()
    await sendStateUpdate()
    return {
      mode: runtimeMode,
      url: runtimeUrl,
      info: runtimeInfo,
    }
  }

  const setupScriptPath = path.join(bundledRoot, 'scripts', 'run-roachnet-setup.mjs')
  const result = await spawnManagedNode(
    setupScriptPath,
    bundledRoot,
    {
      ROACHNET_SETUP_NO_BROWSER: '1',
      ROACHNET_NO_BROWSER: '1',
    },
    setupUrlRegex
  )

  runtimeMode = 'setup'
  runtimeUrl = result.url
  runtimeInfo = result.info || null
  writeDiagnosticLog('runtime:ensureManagedMode:setup-ready', {
    runtimeUrl,
    managedServerPid,
  })

  saveInstallerConfig({
    lastOpenedMode: 'setup',
  })
  await sendStateUpdate()

  return {
    mode: runtimeMode,
    url: runtimeUrl,
    info: runtimeInfo,
  }
}

async function getDesktopState() {
  const config = getInstallerConfig()
  const installedRoot = getInstalledRepoRoot(config)
  const setupState = await getManagedSetupState()
  const appHealth = await getManagedAppHealth()
  const serverInfo = runtimeInfo || (await readServerInfo())
  const managedSystemInfo = await getManagedSystemInfoIfAvailable()
  const acceleration = await getAccelerationState(config, {
    aiWorkbench: {
      systemInfo: {
        ok: Boolean(managedSystemInfo),
        data: managedSystemInfo,
      },
    },
  })

  return {
    shell: {
      native: true,
      packaged: app.isPackaged,
      platform: process.platform,
      arch: process.arch,
      version: app.getVersion(),
      configPath: getConfigPath(app),
    },
    config,
    install: {
      installed: Boolean(installedRoot),
      repoRoot: installedRoot,
      setupCompletedAt: config.setupCompletedAt,
      lastLaunchUrl: config.lastLaunchUrl,
    },
    runtime: {
      mode: runtimeMode,
      running: Boolean(managedProcess && !managedProcess.killed && runtimeMode && runtimeUrl),
      url: runtimeUrl,
      pid: serverInfo?.pid || null,
      serverInfo: serverInfo || null,
      lastError: runtimeLastError,
      appHealth,
    },
    updater: updaterController?.getStatus() || {
      state: 'idle',
      releaseChannel: config.releaseChannel,
      updateBaseUrl: config.updateBaseUrl || null,
      autoCheckUpdates: config.autoCheckUpdates,
    },
    acceleration,
    setup: setupState,
  }
}

function applyDesktopPreferences(config = getInstallerConfig()) {
  if (process.platform === 'darwin' || process.platform === 'win32') {
    try {
      app.setLoginItemSettings({
        openAtLogin: Boolean(config.launchAtLogin),
      })
    } catch (error) {
      writeDiagnosticLog('desktop:setLoginItemSettings:error', formatErrorForDiagnostics(error))
    }
  }
}

function buildChannelMenuItems() {
  const config = getInstallerConfig()

  return RELEASE_CHANNELS.map((channel) => ({
    label: channel[0].toUpperCase() + channel.slice(1),
    type: 'radio',
    checked: config.releaseChannel === channel,
    click: async () => {
      saveInstallerConfig({ releaseChannel: channel })
      await sendStateUpdate()

      if (updaterController && app.isPackaged) {
        try {
          await updaterController.checkForUpdates({ manual: true })
        } catch {}
      }
    },
  }))
}

function buildAppMenu() {
  const config = getInstallerConfig()
  const updateStatus = updaterController?.getStatus() || {
    state: 'idle',
    releaseChannel: config.releaseChannel,
    updateBaseUrl: config.updateBaseUrl || null,
    autoCheckUpdates: config.autoCheckUpdates,
  }

  const template = [
    {
      label: 'RoachNet',
      submenu: [
        {
          label: getInstalledRepoRoot(config) ? 'Start Native Command Deck' : 'Open RoachNet Setup',
          click: async () => {
            if (getInstalledRepoRoot(getInstallerConfig())) {
              ensureManagedMode('app').catch(showBootError)
              return
            }

            await openInstallerHelper().catch(showBootError)
          },
        },
        {
          label: 'Open RoachNet Setup',
          click: async () => {
            await openInstallerHelper().catch(showBootError)
          },
        },
        {
          label: 'Stop Background Services',
          click: async () => {
            stopManagedProcess()
            await sendStateUpdate()
          },
        },
        { type: 'separator' },
        {
          label: `Check For Updates (${updateStatus.releaseChannel})`,
          click: async () => {
            if (!updaterController) {
              return
            }

            try {
              await updaterController.checkForUpdates({ manual: true })
            } catch {}
          },
        },
        {
          label: 'Release Channel',
          submenu: buildChannelMenuItems(),
        },
        {
          label: 'Auto Check Updates',
          type: 'checkbox',
          checked: Boolean(config.autoCheckUpdates),
          click: async () => {
            const nextConfig = saveInstallerConfig({ autoCheckUpdates: !config.autoCheckUpdates })
            if (nextConfig.autoCheckUpdates) {
              updaterController?.start()
            } else {
              updaterController?.stop()
            }
            await sendStateUpdate()
          },
        },
        {
          label: 'Launch At Login',
          type: 'checkbox',
          checked: Boolean(config.launchAtLogin),
          click: async () => {
            saveInstallerConfig({ launchAtLogin: !config.launchAtLogin })
            await sendStateUpdate()
          },
        },
        {
          label: 'Open Release Downloads',
          click: () => {
            shell.openExternal(releasesUrl)
          },
        },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'View',
      submenu: [{ role: 'reload' }, { role: 'toggleDevTools' }, { role: 'resetZoom' }],
    },
  ]

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

function showBootError(error) {
  writeDiagnosticLog('boot:error', formatErrorForDiagnostics(error))
  dialog.showErrorBox(
    'RoachNet failed to start',
    error instanceof Error ? error.message : String(error)
  )
}

function registerIpcHandlers() {
  ipcMain.handle('roachnet:get-state', async () => getDesktopState())

  ipcMain.handle('roachnet:save-config', async (_event, updates = {}) => {
    const nextConfig = saveInstallerConfig(updates)
    await sendStateUpdate()
    return {
      ok: true,
      config: nextConfig,
      state: await getDesktopState(),
    }
  })

  ipcMain.handle('roachnet:start-mode', async (_event, mode = 'auto') => {
    await ensureManagedMode(mode)
    return getDesktopState()
  })

  ipcMain.handle('roachnet:stop-runtime', async () => {
    stopManagedProcess()
    await sendStateUpdate()
    return getDesktopState()
  })

  ipcMain.handle('roachnet:start-container-runtime', async () => {
    await ensureManagedMode('setup')
    const result = await fetchJson(new URL('/api/container-runtime/start', runtimeUrl).toString(), {
      method: 'POST',
      body: {},
      timeoutMs: 180_000,
    })
    await sendStateUpdate()
    return result
  })

  ipcMain.handle('roachnet:run-install', async (_event, payload = {}) => {
    await ensureManagedMode('setup')
    const result = await fetchJson(new URL('/api/install', runtimeUrl).toString(), {
      method: 'POST',
      body: payload,
      timeoutMs: 10_000,
    })
    await sendStateUpdate()
    return result
  })

  ipcMain.handle('roachnet:check-for-updates', async () => {
    if (!updaterController) {
      return { ok: false, reason: 'Updater unavailable' }
    }

    await updaterController.checkForUpdates({ manual: true })
    await sendStateUpdate()
    return { ok: true, state: await getDesktopState() }
  })

  ipcMain.handle('roachnet:open-installer-helper', async () => {
    return openInstallerHelper()
  })

  ipcMain.handle('roachnet:open-install-folder', async () => {
    const installedRoot = getInstalledRepoRoot()

    if (!installedRoot) {
      throw new Error('No installed RoachNet workspace was found yet.')
    }

    const shellError = await shell.openPath(installedRoot)
    if (shellError) {
      throw new Error(shellError)
    }

    return { ok: true }
  })

  ipcMain.handle('roachnet:open-release-downloads', async () => {
    await shell.openExternal(releasesUrl)
    return { ok: true }
  })

  ipcMain.handle('roachnet:open-mlx-docs', async () => {
    await shell.openExternal(mlxDocsUrl)
    return { ok: true }
  })

  ipcMain.handle('roachnet:open-exo-docs', async () => {
    await shell.openExternal(exoRepoUrl)
    return { ok: true }
  })

  ipcMain.handle('roachnet:get-ai-state', async () => {
    return getAIWorkbenchState()
  })

  ipcMain.handle('roachnet:get-acceleration-state', async () => {
    const config = getInstallerConfig()
    const managedSystemInfo = await getManagedSystemInfoIfAvailable()
    return getAccelerationState(config, {
      aiWorkbench: {
        systemInfo: {
          ok: Boolean(managedSystemInfo),
          data: managedSystemInfo,
        },
      },
    })
  })

  ipcMain.handle('roachnet:get-knowledge-state', async () => {
    return getKnowledgeWorkbenchState()
  })

  ipcMain.handle('roachnet:search-models', async (_event, options = {}) => {
    return callManagedAppApi('/api/ollama/models', {
      query: {
        query: options.query || undefined,
        sort: options.sort || 'pulls',
        recommendedOnly: options.recommendedOnly ?? false,
        limit: options.limit || 12,
        force: options.force ?? false,
      },
    })
  })

  ipcMain.handle('roachnet:download-model', async (_event, model) => {
    if (!model || !String(model).trim()) {
      throw new Error('A model name is required.')
    }

    return callManagedAppApi('/api/ollama/models', {
      method: 'POST',
      body: { model: String(model).trim() },
      timeoutMs: 20_000,
    })
  })

  ipcMain.handle('roachnet:delete-model', async (_event, model) => {
    if (!model || !String(model).trim()) {
      throw new Error('A model name is required.')
    }

    return callManagedAppApi('/api/ollama/models', {
      method: 'DELETE',
      body: { model: String(model).trim() },
      timeoutMs: 20_000,
    })
  })

  ipcMain.handle('roachnet:apply-roachclaw', async (_event, payload = {}) => {
    return callManagedAppApi('/api/roachclaw/apply', {
      method: 'POST',
      body: payload,
      timeoutMs: 20_000,
    })
  })

  ipcMain.handle('roachnet:search-skills', async (_event, options = {}) => {
    return callManagedAppApi('/api/openclaw/skills/search', {
      query: {
        query: options.query || '',
        limit: options.limit || 8,
      },
      timeoutMs: 20_000,
    })
  })

  ipcMain.handle('roachnet:install-skill', async (_event, payload = {}) => {
    if (!payload.slug || !String(payload.slug).trim()) {
      throw new Error('A skill slug is required.')
    }

    return callManagedAppApi('/api/openclaw/skills/install', {
      method: 'POST',
      body: {
        slug: String(payload.slug).trim(),
        version: payload.version ? String(payload.version).trim() : undefined,
      },
      timeoutMs: 30_000,
    })
  })

  ipcMain.handle('roachnet:get-chat-session', async (_event, sessionId) => {
    if (!sessionId) {
      throw new Error('A chat session id is required.')
    }

    return callManagedAppApi(`/api/chat/sessions/${sessionId}`)
  })

  ipcMain.handle('roachnet:delete-chat-session', async (_event, sessionId) => {
    if (!sessionId) {
      throw new Error('A chat session id is required.')
    }

    return callManagedAppApi(`/api/chat/sessions/${sessionId}`, {
      method: 'DELETE',
      timeoutMs: 10_000,
    })
  })

  ipcMain.handle('roachnet:send-chat-message', async (_event, payload = {}) => {
    const requestedModel = String(payload.model || '').trim()
    const content = String(payload.content || '').trim()

    if (!content) {
      throw new Error('A chat prompt is required.')
    }

    const routeInfo = await resolveChatExecutionRoute()
    const model =
      routeInfo.route === 'exo'
        ? routeInfo.model || requestedModel
        : routeInfo.route === 'mlx'
          ? routeInfo.model || requestedModel
          : requestedModel

    if (!model) {
      throw new Error('A model is required for chat.')
    }

    let sessionId = payload.sessionId ? Number(payload.sessionId) : null
    if (!sessionId) {
      const title = content.slice(0, 60) || 'New Chat'
      const createdSession = await callManagedAppApi('/api/chat/sessions', {
        method: 'POST',
        body: {
          title,
          model,
        },
      })
      sessionId = createdSession.id
    }

    const existingSession = await callManagedAppApi(`/api/chat/sessions/${sessionId}`)
    const existingMessages = Array.isArray(existingSession.messages) ? existingSession.messages : []
    const messages = existingMessages.map((message) => ({
      role: message.role,
      content: message.content,
    }))

    if (routeInfo.route === 'exo' || routeInfo.route === 'mlx') {
      await updateSessionModel(sessionId, existingSession.title || content.slice(0, 60) || 'New Chat', model)
      await appendSessionMessage(sessionId, 'user', content)

      const response = await callOpenAICompatibleChat(routeInfo.baseUrl, {
        model,
        messages: [
          ...messages,
          {
            role: 'user',
            content,
          },
        ],
        temperature: payload.temperature ?? 0.7,
      })

      const assistantContent = getOpenAICompatibleMessageContent(response)
      if (assistantContent) {
        await appendSessionMessage(sessionId, 'assistant', assistantContent)
      }

      return {
        sessionId,
        route: routeInfo.route,
        response,
        session: await callManagedAppApi(`/api/chat/sessions/${sessionId}`),
      }
    }

    messages.push({
      role: 'user',
      content,
    })

    const response = await callManagedAppApi('/api/ollama/chat', {
      method: 'POST',
      body: {
        model,
        messages,
        stream: false,
        sessionId,
      },
      timeoutMs: 120_000,
    })

    return {
      sessionId,
      route: 'ollama',
      response,
      session: await callManagedAppApi(`/api/chat/sessions/${sessionId}`),
    }
  })

  ipcMain.handle('roachnet:scan-knowledge-storage', async () => {
    return callManagedAppApi('/api/rag/sync', {
      method: 'POST',
      timeoutMs: 120_000,
    })
  })

  ipcMain.handle('roachnet:delete-knowledge-file', async (_event, source) => {
    if (!source || !String(source).trim()) {
      throw new Error('A knowledge source path is required.')
    }

    return callManagedAppApi('/api/rag/files', {
      method: 'DELETE',
      body: { source: String(source).trim() },
      timeoutMs: 60_000,
    })
  })

  ipcMain.handle('roachnet:select-and-upload-knowledge-files', async () => {
    const selection = await dialog.showOpenDialog(mainWindow || undefined, {
      title: 'Add Knowledge Files To RoachNet',
      properties: ['openFile', 'multiSelections'],
      filters: [
        {
          name: 'Knowledge Files',
          extensions: ['txt', 'md', 'pdf', 'png', 'jpg', 'jpeg', 'webp', 'gif'],
        },
        { name: 'All Files', extensions: ['*'] },
      ],
    })

    if (selection.canceled || !selection.filePaths.length) {
      return {
        canceled: true,
        uploads: [],
      }
    }

    const uploads = []
    for (const filePath of selection.filePaths) {
      uploads.push({
        filePath,
        result: await uploadFileToManagedApp(filePath),
      })
    }

    return {
      canceled: false,
      uploads,
    }
  })
}

app.on('window-all-closed', () => {
  writeDiagnosticLog('app:window-all-closed', { platform: process.platform })
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

app.on('second-instance', () => {
  writeDiagnosticLog('app:second-instance')

  if (mainWindow) {
    if (mainWindow.isMinimized()) {
      mainWindow.restore()
    }

    mainWindow.show()
    mainWindow.focus()
  }
})

app.on('activate', async () => {
  writeDiagnosticLog('app:activate', { hasMainWindow: Boolean(mainWindow) })
  if (!mainWindow) {
    mainWindow = createMainWindow()
    buildAppMenu()
    await mainWindow.loadFile(getRendererEntryPath())
    await ensureManagedMode(getInstallerConfig().lastOpenedMode || 'auto').catch(showBootError)
    await sendStateUpdate()
  }
})

app.on('before-quit', () => {
  writeDiagnosticLog('app:before-quit')
  updaterController?.stop()
  stopManagedProcess()
})

app.whenReady()
  .then(async () => {
    writeDiagnosticLog('app:ready', {
      packaged: app.isPackaged,
      version: app.getVersion(),
      platform: process.platform,
      arch: process.arch,
      userData: app.getPath('userData'),
      renderer: getRendererEntryPath(),
      bundledRoot: getBundledWorkspaceRoot(),
    })

    registerIpcHandlers()
    applyDesktopPreferences()
    updaterController = createUpdaterController({
      app,
      getWindow: () => mainWindow,
      readConfig,
    })

    buildAppMenu()
    mainWindow = createMainWindow()
    await mainWindow.loadFile(getRendererEntryPath())
    writeDiagnosticLog('app:renderer-loaded')
    updaterController.start()
    await ensureManagedMode('auto').catch(showBootError)
    await sendStateUpdate()
    writeDiagnosticLog('app:startup-complete')
  })
  .catch((error) => {
    writeDiagnosticLog('app:ready:failed', formatErrorForDiagnostics(error))
    showBootError(error)
    app.exit(1)
  })
