const owner = 'AHGRoach'
const repo = 'RoachNet'
const latestReleaseApi = `https://api.github.com/repos/${owner}/${repo}/releases/latest`
const latestReleasePage = `https://github.com/${owner}/${repo}/releases/latest`
const hostedDownloads = {
  mac: {
    url: './downloads/RoachNet-Setup-macOS.dmg',
    name: 'RoachNet-Setup-macOS.dmg',
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

const platformPresets = {
  mac: {
    label: 'macOS',
    patterns: [/RoachNet-Setup-.*-mac-.*\.dmg$/i, /RoachNet-Setup-.*-mac-.*\.zip$/i],
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
      button.textContent = `Download RoachNet for ${label}`
      button.onclick = () => {
        window.location.href = hostedAsset.url
      }
    })
    downloadMeta.textContent = `Starts with RoachNet Setup · ${hostedAsset.name}`
    return
  }

  if (asset) {
    primaryButtons.forEach((button) => {
      button.textContent = `Download RoachNet for ${label}`
      button.onclick = () => {
        window.location.href = asset.browser_download_url
      }
    })
    downloadMeta.textContent = `Starts with RoachNet Setup · ${asset.name}`
    return
  }

  primaryButtons.forEach((button) => {
    button.textContent = `View ${label} release`
    button.onclick = () => {
      window.open(latestReleasePage, '_blank', 'noopener,noreferrer')
    }
  })
  downloadMeta.textContent = `No direct ${label} installer is posted yet. Opening the latest release instead.`
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
      downloadMeta.textContent = 'The live release feed is unavailable. Opening the latest release instead.'
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
