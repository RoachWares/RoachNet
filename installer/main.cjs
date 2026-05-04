const { app, BrowserWindow, dialog, nativeImage, shell, ipcMain } = require('electron')
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const fsp = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const { getConfigPath, readConfig } = require('../desktop/config.cjs')

const setupUrlRegex = /RoachNet Setup is available at (http:\/\/\S+)/i
const mainReleaseUrl = 'https://github.com/RoachWares/RoachNet/releases'
const dockerDesktopUrl = 'https://docs.docker.com/desktop/'
const setupReadyPollIntervalMs = 250
const setupReadyTimeoutMs = 30_000

let mainWindow = null
let setupProcess = null
let setupUrl = null
let setupError = null
let setupBootPromise = null

const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
}

function getBundledWorkspaceRoot() {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, 'app.asar.unpacked')
  }

  return path.resolve(__dirname, '..')
}

function getRendererEntryPath() {
  return path.join(__dirname, 'renderer', 'index.html')
}

function getSetupReadyFilePath() {
  return path.join(app.getPath('userData'), 'setup-core-ready.json')
}

function clearSetupReadyFile() {
  fs.rmSync(getSetupReadyFilePath(), { force: true })
}

function getSetupNodeEnv() {
  const appBundlePath =
    process.platform === 'darwin'
      ? path.resolve(app.getPath('exe'), '..', '..', '..')
      : path.dirname(app.getPath('exe'))

  return {
    ...process.env,
    ELECTRON_RUN_AS_NODE: '1',
    ROACHNET_NO_BROWSER: '1',
    ROACHNET_SETUP_NO_BROWSER: '1',
    ROACHNET_INSTALLER_CONFIG_PATH: getConfigPath(app),
    ROACHNET_SETUP_APP_BUNDLE: appBundlePath,
    ROACHNET_SETUP_EXE_PATH: app.getPath('exe'),
    ROACHNET_APP_VERSION: app.getVersion(),
    ROACHNET_SETUP_READY_FILE: getSetupReadyFilePath(),
  }
}

function createWindow() {
  const iconPath = path.join(__dirname, '..', 'desktop', 'assets', 'icon.png')
  const icon = fs.existsSync(iconPath) ? nativeImage.createFromPath(iconPath) : undefined

  const window = new BrowserWindow({
    width: 1480,
    height: 980,
    minWidth: 1120,
    minHeight: 760,
    resizable: true,
    movable: true,
    maximizable: true,
    fullscreenable: true,
    show: false,
    backgroundColor: '#040906',
    title: 'RoachNet Setup',
    icon,
    titleBarStyle: process.platform === 'darwin' ? 'hidden' : 'default',
    trafficLightPosition: process.platform === 'darwin' ? { x: 18, y: 18 } : undefined,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  })

  window.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url)
    return { action: 'deny' }
  })

  window.webContents.on('will-navigate', (event, url) => {
    if (url.startsWith('file://')) {
      return
    }

    event.preventDefault()
    shell.openExternal(url)
  })

  window.once('ready-to-show', () => {
    window.show()
  })

  window.on('closed', () => {
    mainWindow = null
  })

  return window
}

async function fetchJson(url, options = {}) {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs || 30_000)

  try {
    const response = await fetch(url, {
      method: options.method || 'GET',
      headers: {
        Accept: 'application/json',
        ...(options.body !== undefined ? { 'Content-Type': 'application/json' } : {}),
        ...(options.headers || {}),
      },
      body: options.body !== undefined ? JSON.stringify(options.body) : undefined,
      signal: controller.signal,
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

function stopSetupProcess() {
  if (setupProcess && !setupProcess.killed) {
    setupProcess.kill('SIGTERM')
  }

  setupProcess = null
  setupUrl = null
  setupBootPromise = null
  clearSetupReadyFile()
}

function spawnSetupProcess() {
  return new Promise((resolve, reject) => {
    const readyFilePath = getSetupReadyFilePath()
    const workspaceRoot = getBundledWorkspaceRoot()
    const scriptPath = path.join(workspaceRoot, 'scripts', 'run-roachnet-setup.mjs')

    clearSetupReadyFile()

    const child = spawn(process.execPath, [scriptPath], {
      cwd: workspaceRoot,
      env: getSetupNodeEnv(),
      stdio: ['ignore', 'pipe', 'pipe'],
    })

    setupProcess = child
    let settled = false
    let output = ''
    let readyPoll = null
    let readyTimeout = null

    const cleanup = () => {
      if (readyPoll) {
        clearInterval(readyPoll)
        readyPoll = null
      }

      if (readyTimeout) {
        clearTimeout(readyTimeout)
        readyTimeout = null
      }
    }

    const settleResolve = (url) => {
      if (settled) {
        return
      }

      settled = true
      cleanup()
      resolve(url)
    }

    const settleReject = (error) => {
      if (settled) {
        return
      }

      settled = true
      cleanup()
      reject(error)
    }

    const maybeResolve = (text) => {
      output += text
      const match = output.match(setupUrlRegex)
      if (!match || settled) {
        return
      }

      settleResolve(match[1])
    }

    readyPoll = setInterval(async () => {
      if (settled || !fs.existsSync(readyFilePath)) {
        return
      }

      try {
        const payload = JSON.parse(await fsp.readFile(readyFilePath, 'utf8'))
        if (payload?.url) {
          settleResolve(payload.url)
        }
      } catch {
        // Ignore partial writes while the setup core is still preparing the file.
      }
    }, setupReadyPollIntervalMs)

    readyTimeout = setTimeout(() => {
      settleReject(
        new Error(output.trim() || 'Timed out waiting for RoachNet Setup to finish booting.')
      )
    }, setupReadyTimeoutMs)

    child.stdout.on('data', (chunk) => {
      maybeResolve(chunk.toString())
    })

    child.stderr.on('data', (chunk) => {
      maybeResolve(chunk.toString())
    })

    child.on('error', (error) => {
      settleReject(error)
    })

    child.on('exit', (code) => {
      if (setupProcess === child) {
        setupProcess = null
        setupUrl = null
      }

      settleReject(new Error(output.trim() || `setup core exited with code ${code}`))
    })
  })
}

async function ensureSetupCore() {
  if (setupProcess && !setupProcess.killed && setupUrl) {
    return setupUrl
  }

  if (setupBootPromise) {
    return setupBootPromise
  }

  stopSetupProcess()
  setupError = null
  setupBootPromise = spawnSetupProcess()
    .then((url) => {
      setupUrl = url
      return url
    })
    .finally(() => {
      setupBootPromise = null
    })

  return setupBootPromise
}

async function getSetupState() {
  try {
    const url = await ensureSetupCore()
    return await fetchJson(new URL('/api/state', url).toString())
  } catch (error) {
    setupError = error instanceof Error ? error.message : String(error)
    throw error
  }
}

function getMainAppCandidates() {
  const config = readConfig(app)
  const candidates = []

  if (config.installedAppPath) {
    candidates.push(config.installedAppPath)
  }

  if (process.platform === 'darwin') {
    const appBundlePath = path.resolve(app.getPath('exe'), '..', '..', '..')
    candidates.push(path.join(path.dirname(appBundlePath), 'RoachNet.app'))
    candidates.push('/Applications/RoachNet.app')
  }

  if (process.platform === 'win32') {
    const exeDir = path.dirname(app.getPath('exe'))
    candidates.push(path.join(exeDir, 'RoachNet.exe'))
    candidates.push(path.join(process.env.LOCALAPPDATA || '', 'Programs', 'RoachNet', 'RoachNet.exe'))
  }

  if (process.platform === 'linux') {
    const exeDir = path.dirname(app.getPath('exe'))
    candidates.push(path.join(exeDir, 'RoachNet.AppImage'))
  }

  return candidates.filter(Boolean)
}

async function launchMainApplication() {
  const config = readConfig(app)

  for (const candidate of getMainAppCandidates()) {
    if (!fs.existsSync(candidate)) {
      continue
    }

    if (process.platform === 'darwin') {
      await shell.openPath(candidate)
      return { launched: 'native-app', target: candidate }
    }

    if (process.platform === 'win32' || process.platform === 'linux') {
      spawn(candidate, [], { detached: true, stdio: 'ignore' }).unref()
      return { launched: 'native-app', target: candidate }
    }
  }

  const url = await ensureSetupCore()
  await fetchJson(new URL('/api/launch', url).toString(), {
    method: 'POST',
    body: {
      installPath: config.installPath,
    },
    timeoutMs: 60_000,
  })

  return { launched: 'fallback-launcher', target: config.installPath || null }
}

function registerIpc() {
  ipcMain.handle('setup:get-state', async () => {
    const state = await getSetupState()
    return {
      ...state,
      shell: {
        packaged: app.isPackaged,
        platform: process.platform,
        arch: process.arch,
        version: app.getVersion(),
      },
      setupError,
    }
  })

  ipcMain.handle('setup:save-config', async (_event, updates = {}) => {
    const url = await ensureSetupCore()
    return fetchJson(new URL('/api/config', url).toString(), {
      method: 'POST',
      body: updates,
    })
  })

  ipcMain.handle('setup:start-container-runtime', async () => {
    const url = await ensureSetupCore()
    return fetchJson(new URL('/api/container-runtime/start', url).toString(), {
      method: 'POST',
      body: {},
      timeoutMs: 180_000,
    })
  })

  ipcMain.handle('setup:run-install', async (_event, payload = {}) => {
    const url = await ensureSetupCore()
    return fetchJson(new URL('/api/install', url).toString(), {
      method: 'POST',
      body: payload,
      timeoutMs: 180_000,
    })
  })

  ipcMain.handle('setup:launch-main-app', async () => {
    return launchMainApplication()
  })

  ipcMain.handle('setup:open-docker-docs', async () => {
    await shell.openExternal(dockerDesktopUrl)
    return { ok: true }
  })

  ipcMain.handle('setup:open-install-folder', async () => {
    const config = readConfig(app)
    if (!config.installPath) {
      throw new Error('No install path is configured yet.')
    }

    const shellError = await shell.openPath(config.installPath)
    if (shellError) {
      throw new Error(shellError)
    }

    return { ok: true }
  })

  ipcMain.handle('setup:open-main-downloads', async () => {
    await shell.openExternal(mainReleaseUrl)
    return { ok: true }
  })
}

function showBootError(error) {
  dialog.showErrorBox(
    'RoachNet Setup failed to start',
    error instanceof Error ? error.message : String(error)
  )
}

app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) {
      mainWindow.restore()
    }

    mainWindow.show()
    mainWindow.focus()
  }
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})

app.on('activate', async () => {
  if (!mainWindow) {
    mainWindow = createWindow()
    await Promise.all([ensureSetupCore(), mainWindow.loadFile(getRendererEntryPath())])
  }
})

app.on('before-quit', () => {
  stopSetupProcess()
})

app.whenReady()
  .then(async () => {
    clearSetupReadyFile()
    registerIpc()
    mainWindow = createWindow()
    await Promise.all([ensureSetupCore(), mainWindow.loadFile(getRendererEntryPath())])
  })
  .catch((error) => {
    showBootError(error)
    app.exit(1)
  })
