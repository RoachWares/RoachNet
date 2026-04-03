const owner = 'AHGRoach'
const repo = 'RoachNet'
const releaseVersion = '1.30.7'
const latestReleaseApi = `https://api.github.com/repos/${owner}/${repo}/releases/latest`
const latestReleasePage = `https://github.com/${owner}/${repo}/releases/latest`
const latestDownloadBase = `https://github.com/${owner}/${repo}/releases/latest/download`
const hostedDownloads = {
  mac: {
    url: `${latestDownloadBase}/RoachNet-Setup-macOS.dmg`,
    name: 'RoachNet-Setup-macOS.dmg',
    version: releaseVersion,
  },
}

const primaryDownloadButton = document.querySelector('#primary-download')
const downloadsPrimaryButton = document.querySelector('#downloads-primary')
const downloadMeta = document.querySelector('#download-meta')
const platformButtons = [...document.querySelectorAll('[data-platform]')]
const commandLaunchButton = document.querySelector('#command-launch')
const commandPalette = document.querySelector('#command-palette')
const commandScrim = document.querySelector('#command-scrim')
const commandInput = document.querySelector('#command-input')
const commandItems = [...document.querySelectorAll('.command-item')]
const heroTime = document.querySelector('[data-hero-time]')
const heroConnectivity = document.querySelector('[data-hero-connectivity]')
const heroStorage = document.querySelector('[data-hero-storage]')
const appStoreGrid = document.querySelector('#app-store-grid')
const appStoreUpdated = document.querySelector('#app-store-updated')

const platformPresets = {
  mac: {
    label: 'macOS',
    patterns: [/^RoachNet-Setup-macOS\.dmg$/i, /RoachNet-Setup-.*-mac-.*\.dmg$/i, /RoachNet-Setup-.*-mac-.*\.zip$/i],
  },
  win: {
    label: 'Windows 11',
    patterns: [/RoachNet-Setup-.*-win-.*\.exe$/i],
  },
  linux: {
    label: 'Linux',
    patterns: [/RoachNet-Setup-.*-linux-.*\.AppImage$/i, /RoachNet-Setup-.*-linux-.*\.deb$/i],
  },
}

let latestRelease = null
let activePlatform = detectPlatform()
let selectedCommandIndex = -1
let timeTicker = null

const fallbackCatalog = {
  updatedAt: '2026-04-02T22:10:00-04:00',
  items: [
    {
      title: 'Field Maps',
      kind: 'Mirror',
      size: '2-40 GB',
      status: 'Design ready',
      source: 'Geofabrik + curated packs',
      summary: 'Versioned regional map packs with resumable downloads, integrity checks, and direct install into the RoachNet maps lane.',
      primaryLabel: 'Open maps manifest',
      primaryUrl: './collections/maps.json',
    },
    {
      title: 'Knowledge Shelf',
      kind: 'Archive',
      size: '4-90 GB',
      status: 'Cataloging',
      source: 'Kiwix, ZIM, offline docs',
      summary: 'Wikipedia, medical references, and long-lived docs mirrored behind roachnet.org manifests instead of raw upstream URLs.',
      primaryLabel: 'Open knowledge manifest',
      primaryUrl: './collections/kiwix-categories.json',
    },
    {
      title: 'RoachClaw Model Packs',
      kind: 'AI',
      size: '1-20 GB',
      status: 'Contained',
      source: 'Ollama + RoachNet curation',
      summary: 'Machine-aware recommended models for contained first boot, with cloud lane fallback and local download guidance inside the app.',
      primaryLabel: `Download RoachNet ${releaseVersion}`,
      primaryUrl: hostedDownloads.mac.url,
    },
    {
      title: 'Developer Toolchain',
      kind: 'Tools',
      size: '500 MB-8 GB',
      status: 'Design ready',
      source: 'Jam, CyberChef, Dev surfaces',
      summary: 'Future Jam-ready utilities, data-lab tools, and RoachNet Dev workspace downloads can ride the same mirror-backed catalog instead of a mess of installer links.',
      primaryLabel: 'Open tooling manifest',
      primaryUrl: './collections/wikipedia.json',
    },
  ],
}

function markActivePlatform(platformKey) {
  platformButtons.forEach((button) => {
    button.dataset.active = button.dataset.platform === platformKey ? 'true' : 'false'
  })
}

function detectPlatform() {
  const ua = navigator.userAgent.toLowerCase()
  const platform = navigator.platform.toLowerCase()

  if (platform.includes('mac') || ua.includes('mac os')) {
    return 'mac'
  }

  if (platform.includes('win') || ua.includes('windows')) {
    return 'win'
  }

  return 'linux'
}

function findAssetForPlatform(platformKey) {
  if (!latestRelease?.assets?.length) {
    return null
  }

  const preset = platformPresets[platformKey]
  if (!preset) {
    return null
  }

  for (const pattern of preset.patterns) {
    const match = latestRelease.assets.find((asset) => pattern.test(asset.name))
    if (match) {
      return match
    }
  }

  return null
}

function setPrimaryButton(platformKey) {
  const hostedAsset = hostedDownloads[platformKey]
  const asset = findAssetForPlatform(platformKey)
  const label = platformPresets[platformKey]?.label || 'your system'
  const primaryButtons = [primaryDownloadButton, downloadsPrimaryButton].filter(Boolean)

  if (!primaryButtons.length) {
    return
  }

  activePlatform = platformKey
  markActivePlatform(platformKey)

  if (hostedAsset) {
    primaryButtons.forEach((button) => {
      button.textContent = `Download RoachNet ${hostedAsset.version} for ${label}`
      button.onclick = () => {
        window.location.href = hostedAsset.url
      }
    })
    if (downloadMeta) {
      downloadMeta.textContent = `Starts with RoachNet Setup v${hostedAsset.version} · ${hostedAsset.name}`
    }
    return
  }

  if (asset) {
    const assetVersion =
      latestRelease?.tag_name?.replace(/^v/i, '') ||
      hostedAsset?.version ||
      releaseVersion
    primaryButtons.forEach((button) => {
      button.textContent = `Download RoachNet ${assetVersion} for ${label}`
      button.onclick = () => {
        window.location.href = asset.browser_download_url
      }
    })
    if (downloadMeta) {
      downloadMeta.textContent = `Starts with RoachNet Setup v${assetVersion} · ${asset.name}`
    }
    return
  }

  primaryButtons.forEach((button) => {
    button.textContent = `View ${label} release`
    button.onclick = () => {
      window.open(latestReleasePage, '_blank', 'noopener,noreferrer')
    }
  })
  if (downloadMeta) {
    downloadMeta.textContent = `No direct ${label} installer is posted yet. Opening the latest release instead.`
  }
}

function formatCompactBytes(bytes) {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return '0 GB'
  }

  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let value = bytes
  let unitIndex = 0

  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024
    unitIndex += 1
  }

  const precision = value >= 10 || unitIndex === 0 ? 0 : 1
  return `${value.toFixed(precision)} ${units[unitIndex]}`
}

function updateHeroTime() {
  if (!heroTime) {
    return
  }

  heroTime.textContent = new Intl.DateTimeFormat(undefined, {
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date())
}

function updateConnectivity() {
  if (!heroConnectivity) {
    return
  }

  const isOnline = navigator.onLine
  heroConnectivity.dataset.state = isOnline ? 'online' : 'offline'
  heroConnectivity.textContent = isOnline ? 'Online Now' : 'Offline Ready'
}

async function updateStorageEstimate() {
  if (!heroStorage) {
    return
  }

  if (!navigator.storage?.estimate) {
    heroStorage.textContent = 'Disk check in app'
    return
  }

  try {
    const { quota = 0, usage = 0 } = await navigator.storage.estimate()
    const available = Math.max(0, quota - usage)

    if (!available) {
      heroStorage.textContent = 'Storage estimate unavailable'
      return
    }

    heroStorage.textContent = `${formatCompactBytes(available)} storage est.`
  } catch (error) {
    heroStorage.textContent = 'Storage estimate unavailable'
    console.error(error)
  }
}

function startHeroTelemetry() {
  updateHeroTime()
  updateConnectivity()
  updateStorageEstimate()

  if (timeTicker) {
    window.clearInterval(timeTicker)
  }

  timeTicker = window.setInterval(updateHeroTime, 30_000)
  window.addEventListener('online', updateConnectivity)
  window.addEventListener('offline', updateConnectivity)
}

function renderAppStoreCatalog(catalog) {
  if (!appStoreGrid) {
    return
  }

  const items = Array.isArray(catalog?.items) ? catalog.items : []

  appStoreGrid.innerHTML = items
    .map(
      (item) => `
        <article class="app-store-card">
          <div class="app-store-card__meta">
            <span class="feature-card__eyebrow">${item.kind}</span>
            <span class="app-store-card__status">${item.status}</span>
          </div>
          <h3>${item.title}</h3>
          <p>${item.summary}</p>
          <div class="app-store-card__footer">
            <span>${item.size}</span>
            <span>${item.source}</span>
          </div>
          ${
            item.primaryUrl
              ? `<a class="app-store-card__action" href="${item.primaryUrl}">${item.primaryLabel || 'Open resource'}</a>`
              : ''
          }
        </article>
      `
    )
    .join('')

  if (appStoreUpdated) {
    const updated = catalog?.updatedAt ? new Date(catalog.updatedAt) : null
    appStoreUpdated.textContent =
      updated && !Number.isNaN(updated.valueOf())
        ? `Catalog updated ${new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(updated)}`
        : 'Catalog preview'
  }
}

async function loadAppStoreCatalog() {
  renderAppStoreCatalog(fallbackCatalog)

  try {
    const response = await fetch('./app-store-catalog.json', {
      headers: {
        Accept: 'application/json',
      },
    })

    if (!response.ok) {
      throw new Error(`${response.status} ${response.statusText}`)
    }

    const catalog = await response.json()
    renderAppStoreCatalog(catalog)
  } catch (error) {
    console.error(error)
  }
}

async function loadLatestRelease() {
  const detectedPlatform = activePlatform
  if (hostedDownloads[detectedPlatform]) {
    setPrimaryButton(detectedPlatform)
  }

  try {
    const response = await fetch(latestReleaseApi, {
      headers: {
        Accept: 'application/vnd.github+json',
      },
    })

    if (!response.ok) {
      throw new Error(`${response.status} ${response.statusText}`)
    }

    latestRelease = await response.json()
    setPrimaryButton(detectedPlatform)
  } catch (error) {
    if (!hostedDownloads[detectedPlatform]) {
      ;[primaryDownloadButton, downloadsPrimaryButton].filter(Boolean).forEach((button) => {
        button.textContent = 'Open latest release'
        button.onclick = () => {
          window.open(latestReleasePage, '_blank', 'noopener,noreferrer')
        }
      })
      if (downloadMeta) {
        downloadMeta.textContent = 'The live release feed is unavailable. Opening the latest release instead.'
      }
    }
    console.error(error)
  }
}

platformButtons.forEach((button) => {
  button.addEventListener('click', () => {
    const platformKey = button.dataset.platform
    activePlatform = platformKey
    markActivePlatform(platformKey)
    const hostedAsset = hostedDownloads[platformKey]
    const asset = findAssetForPlatform(platformKey)

    if (hostedAsset) {
      window.location.href = hostedAsset.url
      return
    }

    if (asset) {
      window.location.href = asset.browser_download_url
      return
    }

    window.open(latestReleasePage, '_blank', 'noopener,noreferrer')
  })
})

function openCommandPalette() {
  if (!commandPalette) {
    return
  }

  commandPalette.hidden = false
  commandPalette.dataset.state = 'open'
  commandInput?.focus()
  commandInput?.select()
  filterCommandItems('')
}

function closeCommandPalette() {
  if (!commandPalette) {
    return
  }

  commandPalette.dataset.state = 'closed'
  commandPalette.hidden = true
  if (commandInput) {
    commandInput.value = ''
  }
  filterCommandItems('')
}

function visibleCommandItems() {
  return commandItems.filter((item) => !item.hidden)
}

function setSelectedCommandIndex(nextIndex) {
  const visibleItems = visibleCommandItems()
  selectedCommandIndex = visibleItems.length ? Math.max(0, Math.min(nextIndex, visibleItems.length - 1)) : -1

  commandItems.forEach((item) => {
    item.dataset.active = 'false'
    item.setAttribute('aria-selected', 'false')
  })

  if (selectedCommandIndex >= 0) {
    const activeItem = visibleItems[selectedCommandIndex]
    activeItem.dataset.active = 'true'
    activeItem.setAttribute('aria-selected', 'true')
    activeItem.scrollIntoView({ block: 'nearest' })
  }
}

function filterCommandItems(query) {
  const normalized = query.trim().toLowerCase()

  commandItems.forEach((item) => {
    const haystack = (item.dataset.command || '').toLowerCase()
    const matches = !normalized || haystack.includes(normalized)
    item.hidden = !matches
  })

  setSelectedCommandIndex(0)
}

function runCommandItem(item) {
  const action = item.dataset.action
  const scrollTarget = item.dataset.scroll

  if (action === 'download') {
    const hostedAsset = hostedDownloads[activePlatform] || hostedDownloads.mac
    window.location.href = hostedAsset.url
    closeCommandPalette()
    return
  }

  if (action === 'github') {
    window.open(`https://github.com/${owner}/${repo}`, '_blank', 'noopener,noreferrer')
    closeCommandPalette()
    return
  }

  if (scrollTarget) {
    closeCommandPalette()
    document.querySelector(scrollTarget)?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  }
}

commandLaunchButton?.addEventListener('click', openCommandPalette)
commandScrim?.addEventListener('click', closeCommandPalette)

commandInput?.addEventListener('input', (event) => {
  filterCommandItems(event.currentTarget.value)
})

commandInput?.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    event.preventDefault()
    closeCommandPalette()
    return
  }

  if (event.key === 'Enter') {
    event.preventDefault()
    const visibleItems = visibleCommandItems()
    const activeItem = visibleItems[selectedCommandIndex] || visibleItems[0]
    if (activeItem) {
      runCommandItem(activeItem)
    }
    return
  }

  if (event.key === 'ArrowDown') {
    event.preventDefault()
    setSelectedCommandIndex(selectedCommandIndex + 1)
    return
  }

  if (event.key === 'ArrowUp') {
    event.preventDefault()
    setSelectedCommandIndex(selectedCommandIndex - 1)
  }
})

commandItems.forEach((item) => {
  item.addEventListener('click', () => {
    runCommandItem(item)
  })

  item.addEventListener('mousemove', () => {
    const visibleItems = visibleCommandItems()
    const nextIndex = visibleItems.indexOf(item)
    if (nextIndex >= 0 && nextIndex !== selectedCommandIndex) {
      setSelectedCommandIndex(nextIndex)
    }
  })
})

document.addEventListener('keydown', (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
    event.preventDefault()
    if (commandPalette?.hidden === false) {
      closeCommandPalette()
    } else {
      openCommandPalette()
    }
    return
  }

  if (event.key === 'Escape' && commandPalette?.hidden === false) {
    event.preventDefault()
    closeCommandPalette()
  }
})

loadLatestRelease()
startHeroTelemetry()
loadAppStoreCatalog()
