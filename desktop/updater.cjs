const { dialog } = require('electron')
const log = require('electron-log/main')
const { autoUpdater } = require('electron-updater')

const UPDATE_CHECK_INTERVAL_MS = 1000 * 60 * 60 * 6

function mapReleaseChannel(channel) {
  return channel === 'stable' ? 'latest' : channel
}

function configureUpdater(config) {
  log.initialize()

  autoUpdater.logger = log
  autoUpdater.autoInstallOnAppQuit = true
  autoUpdater.autoRunAppAfterInstall = true
  autoUpdater.autoDownload = Boolean(config.autoDownloadUpdates)
  autoUpdater.allowDowngrade = true
  autoUpdater.allowPrerelease = config.releaseChannel !== 'stable'
  autoUpdater.channel = mapReleaseChannel(config.releaseChannel)

  if (config.updateBaseUrl) {
    autoUpdater.setFeedURL({
      provider: 'generic',
      url: config.updateBaseUrl,
      channel: mapReleaseChannel(config.releaseChannel),
    })
  }
}

function createUpdaterController({ app, getWindow, readConfig }) {
  let updateStatus = 'idle'
  let updateTimer = null

  const showMessage = async (options) => {
    const window = getWindow?.() || null
    return dialog.showMessageBox(window || undefined, options)
  }

  const currentConfig = () => readConfig(app)

  const ensureConfigured = () => {
    configureUpdater(currentConfig())
  }

  autoUpdater.on('checking-for-update', () => {
    updateStatus = 'checking'
  })

  autoUpdater.on('update-available', (info) => {
    updateStatus = 'available'
    log.info(`[RoachNet Updater] Update available: ${info.version}`)
  })

  autoUpdater.on('update-not-available', (info) => {
    updateStatus = 'idle'
    log.info(`[RoachNet Updater] No update available. Current latest: ${info.version}`)
  })

  autoUpdater.on('error', async (error) => {
    updateStatus = 'error'
    log.error('[RoachNet Updater] Update error', error)
  })

  autoUpdater.on('download-progress', (progress) => {
    updateStatus = 'downloading'
    log.info(
      `[RoachNet Updater] Downloading update: ${Math.round(progress.percent)}% (${progress.bytesPerSecond} B/s)`
    )
  })

  autoUpdater.on('update-downloaded', async (event) => {
    updateStatus = 'downloaded'

    const result = await showMessage({
      type: 'info',
      buttons: ['Restart Now', 'Later'],
      defaultId: 0,
      cancelId: 1,
      title: 'RoachNet Update Ready',
      message: `RoachNet ${event.version} has been downloaded.`,
      detail: 'Restart now to apply the new native build.',
    })

    if (result.response === 0) {
      autoUpdater.quitAndInstall(false, true)
    }
  })

  async function checkForUpdates(options = {}) {
    if (!app.isPackaged) {
      return { skipped: true, reason: 'RoachNet updater is disabled for unpackaged development runs.' }
    }

    const config = currentConfig()
    if (!config.autoCheckUpdates && !options.manual) {
      return { skipped: true, reason: 'Automatic update checks are disabled.' }
    }

    ensureConfigured()

    try {
      const result = await autoUpdater.checkForUpdates()

      if (options.manual && !result?.downloadPromise) {
        await showMessage({
          type: 'info',
          buttons: ['OK'],
          title: 'RoachNet',
          message: 'RoachNet is up to date.',
          detail: `Channel: ${config.releaseChannel.toUpperCase()}`,
        })
      }

      return result
    } catch (error) {
      if (options.manual) {
        await showMessage({
          type: 'error',
          buttons: ['OK'],
          title: 'RoachNet Update Check Failed',
          message: 'RoachNet could not complete the update check.',
          detail: error instanceof Error ? error.message : String(error),
        })
      }

      throw error
    }
  }

  function start() {
    if (!app.isPackaged) {
      return
    }

    const config = currentConfig()
    if (!config.autoCheckUpdates) {
      return
    }

    ensureConfigured()
    clearInterval(updateTimer)
    updateTimer = setInterval(() => {
      checkForUpdates().catch((error) => {
        log.warn('[RoachNet Updater] Background update check failed', error)
      })
    }, UPDATE_CHECK_INTERVAL_MS)

    setTimeout(() => {
      checkForUpdates().catch((error) => {
        log.warn('[RoachNet Updater] Initial update check failed', error)
      })
    }, 15_000)
  }

  function stop() {
    clearInterval(updateTimer)
    updateTimer = null
  }

  function getStatus() {
    const config = currentConfig()
    return {
      state: updateStatus,
      releaseChannel: config.releaseChannel,
      updateBaseUrl: config.updateBaseUrl || null,
      autoCheckUpdates: config.autoCheckUpdates,
    }
  }

  return {
    checkForUpdates,
    getStatus,
    start,
    stop,
  }
}

module.exports = {
  createUpdaterController,
  mapReleaseChannel,
}
