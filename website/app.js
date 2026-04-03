const owner = 'AHGRoach'
const repo = 'RoachNet'
const releaseVersion = '1.4'
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
const appStoreFilterBar = document.querySelector('#app-store-filter-bar')
const appStoreSearchInput = document.querySelector('#app-store-search')
const appStoreResults = document.querySelector('#app-store-results')
const appStoreFeatured = document.querySelector('#app-store-featured')
const appStoreCurated = document.querySelector('#app-store-curated')
const appStoreGrid = document.querySelector('#app-store-grid')
const appStoreUpdated = document.querySelector('#app-store-updated')
const appDetailOverlay = document.querySelector('#app-detail-overlay')
const appDetailContent = document.querySelector('#app-detail-content')
const appDetailClose = document.querySelector('#app-detail-close')
const appsCountStat = document.querySelector('#apps-count')
const appsSectionsCountStat = document.querySelector('#apps-sections-count')
const appsToolbarStats = document.querySelector('#apps-toolbar-stats')

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
let appStoreCatalog = null
let appStoreActiveSection = 'All'
let appStoreSearchQuery = ''
let featuredRotationTimer = null
let featuredRotationItems = []
let featuredRotationIndex = 0
let storeRevealObserver = null

const storeSectionMeta = {
  'Map Regions': {
    eyebrow: 'Offline atlas',
    blurb: 'Regional packs that keep the field map lane useful when the network is gone.',
  },
  Medicine: {
    eyebrow: 'Care library',
    blurb: 'Medical references and quick-response libraries you can keep close on the machine.',
  },
  'Survival & Preparedness': {
    eyebrow: 'Field guides',
    blurb: 'Preparedness manuals, survival references, and practical offline field material.',
  },
  'Education & Reference': {
    eyebrow: 'Reference shelf',
    blurb: 'Course material and reference libraries curated into installable study packs.',
  },
  'DIY & Repair': {
    eyebrow: 'Repair shelf',
    blurb: 'Fix guides, repair notes, and hands-on practical references for the real world.',
  },
  'Agriculture & Food': {
    eyebrow: 'Grow & cook',
    blurb: 'Food, growing, and practical production references mirrored into the RoachNet vault.',
  },
  'Software Development': {
    eyebrow: 'Dev courses',
    blurb: 'Focused software-development installs that land in the Education and Dev lanes cleanly.',
  },
  'Machine Learning & Data Science': {
    eyebrow: 'ML packs',
    blurb: 'Modeling, data-science, and ML course packs that stay available offline.',
  },
  'Music Production & Audio': {
    eyebrow: 'Audio craft',
    blurb: 'Production, sound-design, and audio-engineering material for studio sessions.',
  },
  'IT & Infrastructure': {
    eyebrow: 'Infra shelf',
    blurb: 'Networking, systems, and infrastructure learning packs for operators and builders.',
  },
  Wikipedia: {
    eyebrow: 'Quick reference',
    blurb: 'Wikipedia snapshots trimmed into practical install targets instead of giant archives.',
  },
  'Model Packs': {
    eyebrow: 'RoachClaw models',
    blurb: 'Contained RoachClaw-ready model installs for the native AI lane.',
  },
}

const fallbackCatalog = {
  updatedAt: '2026-04-03T14:45:00-04:00',
  featuredId: 'base-atlas',
  items: [
    {
      id: 'base-atlas',
      title: 'Base Atlas',
      subtitle: 'Core renderer and shared basemap',
      category: 'Maps',
      section: 'Field Ops',
      size: '320 MB',
      status: 'Ready',
      source: 'RoachNet mirror',
      icon: './assets/app-store/base-atlas.svg',
      summary:
        'Install the shared vector atlas and base map assets first so regional packs open cleanly inside the RoachNet Maps lane.',
      featured: true,
      accent: 'blue',
      machineFit: 'Best first install on every supported Mac',
      includes: [
        'Shared vector atlas and renderer assets',
        'Required before regional map collections',
        'Installs directly into the native Maps lane',
      ],
      installLabel: 'Install to RoachNet',
      detailLabel: 'View manifest',
      detailUrl: './collections/maps.json',
      installIntent: {
        action: 'base-map-assets',
      },
    },
    {
      id: 'pacific-region',
      title: 'Pacific Region',
      subtitle: 'Alaska, California, Hawaii, Oregon, Washington',
      category: 'Maps',
      section: 'Field Ops',
      size: '2.6 GB',
      status: 'Ready',
      source: 'Geofabrik + curated packs',
      icon: './assets/app-store/pacific-region.svg',
      summary:
        'Queue the Pacific regional collection directly into RoachNet so the field map lane is useful immediately after install.',
      accent: 'blue',
      machineFit: 'Ideal once Base Atlas is already installed',
      includes: [
        'Pacific region collection manifest',
        'Regional downloads for Alaska, California, Hawaii, Oregon, and Washington',
        'Mapped install path inside the field-ops shelf',
      ],
      installLabel: 'Install to RoachNet',
      detailLabel: 'Open collection',
      detailUrl: './collections/maps.json',
      installIntent: {
        action: 'map-collection',
        slug: 'pacific',
      },
    },
    {
      id: 'course-freecodecamp-javascript',
      title: 'freeCodeCamp: JavaScript Algorithms and Data Structures',
      subtitle: 'A compact coding course mirrored into the RoachNet Education lane',
      category: 'Essential',
      section: 'Software Development',
      size: '7 MB',
      status: 'Great first install',
      source: 'freeCodeCamp via Kiwix',
      summary:
        'Install one real course instead of a giant provider bundle. This entry opens RoachNet and queues the focused freeCodeCamp JavaScript course directly into the native app.',
      accent: 'violet',
      machineFit: 'Fast add-on for any supported machine',
      includes: [
        'Focused JavaScript fundamentals course',
        'One-course install handoff into RoachNet',
        'Good first coding shelf for a clean machine',
      ],
      installLabel: 'Install to RoachNet',
      detailLabel: 'Open manifest',
      detailUrl: './collections/kiwix-categories.json',
      installIntent: {
        action: 'education-resource',
        category: 'computing',
        resource: 'freecodecamp_en_javascript-algorithms-and-data-structures',
      },
    },
    {
      id: 'course-open-music-theory',
      title: 'Open Music Theory',
      subtitle: 'Harmony, notation, rhythm, and ear-training in one offline shelf',
      category: 'Essential',
      section: 'Music Production & Audio',
      size: '78 MB',
      status: 'Great first install',
      source: 'Open Music Theory via Kiwix',
      summary:
        'A real course app for RoachNet’s music lane, mirrored cleanly so the user can install focused theory content without dragging in a whole site or provider wrapper.',
      accent: 'magenta',
      machineFit: 'Fast add-on for any supported machine',
      includes: [
        'Open music-theory coursework',
        'Installs directly into the Education lane',
        'Useful for production, arranging, and scoring sessions',
      ],
      installLabel: 'Install to RoachNet',
      detailLabel: 'Open manifest',
      detailUrl: './collections/kiwix-categories.json',
      installIntent: {
        action: 'education-resource',
        category: 'music-audio',
        resource: 'openmusictheory.com_en_all',
      },
    },
    {
      id: 'course-cloudflare-learning-center',
      title: 'Cloudflare Learning Center',
      subtitle: 'Edge, DNS, security, and web-infrastructure docs mirrored offline',
      category: 'Standard',
      section: 'IT & Infrastructure',
      size: '182 MB',
      status: 'Recommended next install',
      source: 'Cloudflare Learning Center via Kiwix',
      summary:
        'A focused infrastructure course app that lands in RoachNet as its own install target instead of masquerading as a generic provider shelf.',
      accent: 'bronze',
      machineFit: 'Easy install once the core workspace is already healthy',
      includes: [
        'Practical edge and networking reference',
        'Offline ops shelf for the RoachNet vault',
        'Direct native install handoff',
      ],
      installLabel: 'Install to RoachNet',
      detailLabel: 'Open manifest',
      detailUrl: './collections/kiwix-categories.json',
      installIntent: {
        action: 'education-resource',
        category: 'it-infrastructure',
        resource: 'cloudflare.com_en_learning-center',
      },
    },
    {
      id: 'roachclaw-quickstart',
      title: 'RoachClaw Quickstart',
      subtitle: 'Contained qwen2.5-coder:1.5b model',
      category: 'AI',
      section: 'AI Packs',
      size: '1-2 GB',
      status: 'Best first boot',
      source: 'Contained Ollama lane',
      icon: './assets/app-store/roachclaw-quickstart.svg',
      summary:
        'Open RoachNet and queue the fast contained starter model so RoachClaw can answer on a clean machine without borrowing a host Ollama install.',
      accent: 'violet',
      machineFit: 'Best on all Apple Silicon Macs, especially 16 GB systems',
      includes: [
        'Contained Ollama-backed model download',
        'RoachClaw bootstrap queue on first launch',
        'Cloud fallback remains available while the model downloads',
      ],
      installLabel: 'Get',
      detailLabel: 'Open RoachClaw',
      detailUrl: 'https://roachnet.org/#screens',
      installIntent: {
        action: 'roachclaw-model',
        model: 'qwen2.5-coder:1.5b',
      },
    },
    {
      id: 'roachclaw-studio',
      title: 'RoachClaw Studio',
      subtitle: 'Contained qwen2.5-coder:7b upgrade',
      category: 'AI',
      section: 'AI Packs',
      size: '4-5 GB',
      status: 'For larger Apple Silicon Macs',
      source: 'Contained Ollama lane',
      icon: './assets/app-store/roachclaw-studio.svg',
      summary:
        'A bigger local coding model for machines with more headroom. Queue it from the site and RoachNet will open directly into the RoachClaw workbench to stage the download.',
      accent: 'violet',
      machineFit: 'Best on M2 Pro, Max, and higher-memory Apple Silicon',
      includes: [
        'Contained 7B coding model queue',
        'RoachClaw workbench handoff',
        'Larger local lane for stronger coding and agent tasks',
      ],
      installLabel: 'Get',
      detailLabel: 'Open RoachClaw',
      detailUrl: 'https://roachnet.org/#screens',
      installIntent: {
        action: 'roachclaw-model',
        model: 'qwen2.5-coder:7b',
      },
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

function normalizeCatalogValue(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function deriveIconMonogram(item) {
  if (item?.iconMonogram) {
    return String(item.iconMonogram).replace(/[^a-z0-9]/gi, '').slice(0, 4).toUpperCase()
  }

  const words = String(item?.title || 'RoachNet')
    .split(/[\s:/-]+/)
    .filter(Boolean)

  if (words.length >= 2) {
    return words
      .slice(0, 3)
      .map((word) => word[0].toUpperCase())
      .join('')
      .slice(0, 4)
  }

  return words.join('').replace(/[^a-z0-9]/gi, '').slice(0, 3).toUpperCase() || 'RN'
}

function deriveIconFamily(item) {
  const haystack = normalizeCatalogValue([item?.section, item?.category, item?.title].join(' '))

  if (haystack.includes('map')) return 'maps'
  if (haystack.includes('medicine')) return 'medicine'
  if (haystack.includes('survival') || haystack.includes('preparedness')) return 'survival'
  if (haystack.includes('education') || haystack.includes('reference')) return 'education'
  if (haystack.includes('repair') || haystack.includes('diy')) return 'repair'
  if (haystack.includes('agriculture') || haystack.includes('food')) return 'agriculture'
  if (haystack.includes('software development') || haystack.includes('dev')) return 'development'
  if (haystack.includes('machine learning') || haystack.includes('data science')) return 'ml'
  if (haystack.includes('audio') || haystack.includes('music')) return 'audio'
  if (haystack.includes('infrastructure') || haystack.includes('it ')) return 'infrastructure'
  if (haystack.includes('wikipedia')) return 'wikipedia'
  if (haystack.includes('model')) return 'models'
  return 'general'
}

function deriveIconGlyph(item, family = deriveIconFamily(item)) {
  switch (family) {
    case 'maps':
      return 'GRID'
    case 'medicine':
      return 'MED'
    case 'survival':
      return 'FIELD'
    case 'education':
      return 'READ'
    case 'repair':
      return 'FIX'
    case 'agriculture':
      return 'ROOT'
    case 'development':
      return 'DEV'
    case 'ml':
      return 'ML'
    case 'audio':
      return 'AUDIO'
    case 'infrastructure':
      return 'NET'
    case 'wikipedia':
      return 'WIKI'
    case 'models':
      return 'AI'
    default:
      return 'RN'
  }
}

function renderStoreIcon(item, variant = 'card') {
  if (item?.icon) {
    return `<img src="${item.icon}" alt="${escapeHtml(item.title)} icon" loading="lazy" />`
  }

  const family = deriveIconFamily(item)
  const glyph = deriveIconGlyph(item, family)

  return `
    <div
      class="store-generated-icon store-generated-icon--${variant}"
      data-icon-family="${family}"
      data-accent="${item?.accent || 'blue'}"
      role="img"
      aria-label="${escapeHtml(item.title)} icon"
    >
      <span class="store-generated-icon__mesh" aria-hidden="true"></span>
      <span class="store-generated-icon__glyph" aria-hidden="true">${escapeHtml(glyph)}</span>
      <span class="store-generated-icon__band">${escapeHtml(item.iconBand || item.category || 'RoachNet')}</span>
      <strong class="store-generated-icon__mono">${escapeHtml(deriveIconMonogram(item))}</strong>
    </div>
  `
}

function buildInstallUrl(item) {
  if (!item?.installIntent) {
    return ''
  }

  const params = new URLSearchParams()
  Object.entries(item.installIntent).forEach(([key, value]) => {
    if (value !== null && value !== undefined && value !== '') {
      params.set(key, value)
    }
  })

  const query = params.toString()
  return query ? `roachnet://install-content?${query}` : 'roachnet://install-content'
}

function attemptNativeInstall(url) {
  if (!url) {
    return
  }

  let completed = false
  let fallbackTimer = null

  const clearFallback = () => {
    completed = true
    if (fallbackTimer) {
      window.clearTimeout(fallbackTimer)
      fallbackTimer = null
    }
    document.removeEventListener('visibilitychange', handleVisibilityChange)
    window.removeEventListener('pagehide', clearFallback)
    window.removeEventListener('blur', handleBlur)
  }

  const handleVisibilityChange = () => {
    if (document.visibilityState === 'hidden') {
      clearFallback()
    }
  }

  const handleBlur = () => {
    window.setTimeout(() => {
      if (document.visibilityState === 'hidden') {
        clearFallback()
      }
    }, 150)
  }

  document.addEventListener('visibilitychange', handleVisibilityChange)
  window.addEventListener('pagehide', clearFallback)
  window.addEventListener('blur', handleBlur)

  fallbackTimer = window.setTimeout(() => {
    if (completed) {
      return
    }
    clearFallback()
    window.location.href = 'https://roachnet.org/#downloads'
  }, 1400)

  window.location.href = url
}

function getCatalogItems(catalog = appStoreCatalog) {
  return Array.isArray(catalog?.items) ? catalog.items : []
}

function getVisibleCatalogItems(catalog = appStoreCatalog) {
  const normalizedQuery = normalizeCatalogValue(appStoreSearchQuery)

  return getCatalogItems(catalog).filter((item) => {
    const matchesSection =
      appStoreActiveSection === 'All' || (item.section || 'Catalog') === appStoreActiveSection

    if (!matchesSection) {
      return false
    }

    if (!normalizedQuery) {
      return true
    }

    const haystack = normalizeCatalogValue([
      item.title,
      item.subtitle,
      item.category,
      item.section,
      item.status,
      item.source,
      item.summary,
      item.machineFit,
      ...(item.includes || []),
    ].join(' '))

    return haystack.includes(normalizedQuery)
  })
}

function updateAppStoreSummary(items) {
  if (appsCountStat) {
    appsCountStat.textContent = String(items.length)
  }

  if (appsSectionsCountStat) {
    appsSectionsCountStat.textContent = String(new Set(items.map((item) => item.section || 'Catalog')).size)
  }

  if (!appsToolbarStats) {
    return
  }

  const topSections = [...items.reduce((map, item) => {
    const key = item.section || 'Catalog'
    map.set(key, (map.get(key) || 0) + 1)
    return map
  }, new Map()).entries()]
    .sort((left, right) => right[1] - left[1])
    .slice(0, 4)

  appsToolbarStats.innerHTML = topSections
    .map(
      ([section, count]) => `
        <article class="apps-toolbar__stat">
          <strong>${count}</strong>
          <span>${section}</span>
        </article>
      `
    )
    .join('')
}

function renderAppStoreFilters(items) {
  if (!appStoreFilterBar) {
    return
  }

  const sections = ['All', ...new Set(items.map((item) => item.section || 'Catalog'))]

  appStoreFilterBar.innerHTML = sections
    .map(
      (section) => `
        <button
          class="app-store-filter${section === appStoreActiveSection ? ' app-store-filter--active' : ''}"
          type="button"
          data-section-filter="${section}"
          aria-pressed="${section === appStoreActiveSection ? 'true' : 'false'}"
        >
          ${section}
        </button>
      `
    )
    .join('')
}

function pickCuratedItems(visibleItems, primaryFeatured) {
  const picks = []
  const seenSections = new Set()

  visibleItems.forEach((item) => {
    if (primaryFeatured && item.id === primaryFeatured.id) {
      return
    }

    const section = item.section || 'Catalog'
    if (seenSections.has(section)) {
      return
    }

    picks.push(item)
    seenSections.add(section)
  })

  return picks.slice(0, 4)
}

function pickFeaturedRotationItems(visibleItems, primaryFeatured) {
  if (!primaryFeatured) {
    return visibleItems.slice(0, 6)
  }

  const picks = [primaryFeatured]
  const seenSections = new Set([primaryFeatured.section || 'Catalog'])

  visibleItems.forEach((item) => {
    if (item.id === primaryFeatured.id || picks.length >= 6) {
      return
    }

    const section = item.section || 'Catalog'
    if (seenSections.has(section)) {
      return
    }

    picks.push(item)
    seenSections.add(section)
  })

  if (picks.length < Math.min(6, visibleItems.length)) {
    visibleItems.forEach((item) => {
      if (item.id === primaryFeatured.id || picks.length >= 6 || picks.some((candidate) => candidate.id === item.id)) {
        return
      }
      picks.push(item)
    })
  }

  return picks
}

function renderCuratedStoreStrip(visibleItems, primaryFeatured) {
  if (!appStoreCurated) {
    return
  }

  const picks = pickCuratedItems(visibleItems, primaryFeatured)
  if (!picks.length) {
    appStoreCurated.innerHTML = ''
    return
  }

  appStoreCurated.innerHTML = `
    <section class="app-store-curated__section" data-reveal>
      <div class="app-store-curated__head">
        <div>
          <p class="app-store-curated__eyebrow">Quick installs</p>
          <h3>Install-ready picks from around the RoachNet shelf.</h3>
        </div>
        <span class="app-store-curated__note">Each button hands the selected pack straight into the native app.</span>
      </div>
      <div class="app-store-curated__grid">
        ${picks
          .map((item) => {
            const installUrl = buildInstallUrl(item)
            return `
              <article class="store-quick-card" data-accent="${item.accent || 'blue'}">
                <div class="store-quick-card__top">
                  <div class="store-quick-card__icon">
                    ${renderStoreIcon(item, 'mini')}
                  </div>
                  <div class="store-quick-card__copy">
                    <span class="store-quick-card__section">${item.section}</span>
                    <h4>${item.title}</h4>
                    <p>${item.subtitle || item.source}</p>
                  </div>
                </div>
                <div class="store-quick-card__actions">
                  ${
                    installUrl
                      ? `<a class="store-quick-card__get" href="${installUrl}">${item.installLabel || 'Install to RoachNet'}</a>`
                      : ''
                  }
                  <button class="store-quick-card__preview" type="button" data-preview-id="${item.id}">Preview</button>
                </div>
              </article>
            `
          })
          .join('')}
      </div>
    </section>
  `
}

function renderStoreActionButtons(item, { compact = false, featured = false } = {}) {
  const installUrl = buildInstallUrl(item)
  const installLabel = item.installLabel || 'Get'
  const detailUrl = item.detailUrl || item.primaryUrl
  const detailLabel = item.detailLabel || 'View manifest'

  if (featured) {
    return `
      <div class="store-featured-card__actions">
        ${
          installUrl
            ? `<a class="store-featured-card__primary" href="${installUrl}">${installLabel}</a>`
            : ''
        }
        <button class="store-featured-card__preview" type="button" data-preview-id="${item.id}">Preview</button>
        ${
          detailUrl
            ? `<a class="store-featured-card__secondary" href="${detailUrl}">${detailLabel}</a>`
            : ''
        }
      </div>
    `
  }

  return `
    <div class="store-app-card__actions">
      ${
        installUrl
          ? `<a class="store-app-card__get" href="${installUrl}">${installLabel}</a>`
          : ''
      }
      <button class="store-app-card__preview${compact ? ' store-app-card__preview--compact' : ''}" type="button" data-preview-id="${item.id}">
        Preview
      </button>
    </div>
  `
}

function renderStoreCard(item, compact = false) {
  const highlights = (item.includes || []).slice(0, compact ? 1 : 2)
  const metaItems = [item.size, item.source, item.machineFit].filter(Boolean).slice(0, 3)

  return `
    <article class="store-app-card${compact ? ' store-app-card--compact' : ''}" data-accent="${item.accent || 'blue'}" data-reveal>
      <div class="store-app-card__top">
        <div class="store-app-card__icon">
          ${renderStoreIcon(item, compact ? 'compact' : 'card')}
        </div>
        <div class="store-app-card__copy">
          <div class="store-app-card__eyebrow-row">
            <span class="store-app-card__category">${item.category}</span>
            <span class="store-app-card__status">${item.status}</span>
          </div>
          <h3>${item.title}</h3>
          <p class="store-app-card__subtitle">${item.subtitle || item.source}</p>
        </div>
      </div>
      <p class="store-app-card__summary">${item.summary}</p>
      ${
        highlights.length
          ? `<ul class="store-app-card__bullets">${highlights.map((line) => `<li>${line}</li>`).join('')}</ul>`
          : ''
      }
      <div class="store-app-card__meta">
        ${metaItems.map((value) => `<span>${value}</span>`).join('')}
      </div>
      ${renderStoreActionButtons(item, { compact })}
      <p class="store-app-card__caption">Install opens RoachNet and queues this pack inside the native app.</p>
    </article>
  `
}

function renderFeaturedPagination(items) {
  if (items.length < 2) {
    return ''
  }

  return `
    <div class="store-featured-card__pagination" aria-label="Featured apps carousel">
      ${items
        .map(
          (candidate, index) => `
            <button
              class="store-featured-card__dot${index === featuredRotationIndex ? ' store-featured-card__dot--active' : ''}"
              type="button"
              data-featured-index="${index}"
              aria-label="Show ${candidate.title}"
            >
              <span>${candidate.title}</span>
            </button>
          `
        )
        .join('')}
    </div>
  `
}

function renderFeaturedStoreCard(item, items = []) {
  if (!appStoreFeatured || !item) {
    return
  }

  appStoreFeatured.innerHTML = `
    <article class="store-featured-card" data-accent="${item.accent || 'blue'}" data-reveal>
      <div class="store-featured-card__icon">
        ${renderStoreIcon(item, 'featured')}
      </div>
      <div class="store-featured-card__copy">
        <span class="store-featured-card__eyebrow">Today in RoachNet Apps</span>
        <h3>${item.title}</h3>
        <p class="store-featured-card__subtitle">${item.subtitle || item.source}</p>
        <p class="store-featured-card__summary">${item.summary}</p>
        <div class="store-featured-card__meta">
          <span>${item.category}</span>
          <span>${item.size}</span>
          <span>${item.machineFit || item.source}</span>
        </div>
        ${renderStoreActionButtons(item, { featured: true })}
        ${renderFeaturedPagination(items)}
      </div>
    </article>
  `
}

function stopFeaturedRotation() {
  if (featuredRotationTimer) {
    window.clearInterval(featuredRotationTimer)
    featuredRotationTimer = null
  }
}

function startFeaturedRotation() {
  stopFeaturedRotation()

  if (!appStoreFeatured || featuredRotationItems.length < 2) {
    return
  }

  featuredRotationTimer = window.setInterval(() => {
    featuredRotationIndex = (featuredRotationIndex + 1) % featuredRotationItems.length
    renderFeaturedStoreCard(featuredRotationItems[featuredRotationIndex], featuredRotationItems)
    observeStoreReveals()
  }, 7000)
}

function observeStoreReveals() {
  const revealTargets = document.querySelectorAll('[data-reveal]')
  if (!revealTargets.length) {
    return
  }

  if (!('IntersectionObserver' in window)) {
    revealTargets.forEach((target) => target.classList.add('is-revealed'))
    return
  }

  if (!storeRevealObserver) {
    storeRevealObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add('is-revealed')
            storeRevealObserver.unobserve(entry.target)
          }
        })
      },
      {
        threshold: 0.18,
        rootMargin: '0px 0px -24px 0px',
      }
    )
  }

  revealTargets.forEach((target) => {
    if (!target.dataset.revealBound) {
      target.dataset.revealBound = 'true'
      storeRevealObserver.observe(target)
    }
  })
}

function updateAppStoreResults(visibleItems, totalItems) {
  if (!appStoreResults) {
    return
  }

  const sectionLabel =
    appStoreActiveSection === 'All' ? 'all shelves' : `${appStoreActiveSection.toLowerCase()}`
  const queryLabel = appStoreSearchQuery.trim() ? ` matching “${appStoreSearchQuery.trim()}”` : ''
  appStoreResults.textContent = `Showing ${visibleItems.length} of ${totalItems} apps across ${sectionLabel}${queryLabel}.`
}

function renderEmptyCatalogState() {
  if (!appStoreGrid) {
    return
  }

  appStoreGrid.innerHTML = `
    <section class="app-store-empty" data-reveal>
      <strong>No apps matched this filter.</strong>
      <p>Try a broader section or clear the search term to see the full RoachNet catalog again.</p>
    </section>
  `
  if (appStoreFeatured) {
    appStoreFeatured.innerHTML = ''
  }
  if (appStoreCurated) {
    appStoreCurated.innerHTML = ''
  }
  stopFeaturedRotation()
  observeStoreReveals()
}

function renderAppStoreCatalog(catalog) {
  if (!appStoreGrid) {
    return
  }

  appStoreCatalog = catalog
  const items = getCatalogItems(catalog)
  const storeMode = appStoreGrid.dataset.storeMode || 'full'

  updateAppStoreSummary(items)

  renderAppStoreFilters(items)

  const visibleItems = getVisibleCatalogItems(catalog)
  updateAppStoreResults(visibleItems, items.length)

  if (!visibleItems.length) {
    renderEmptyCatalogState()
    return
  }

  const primaryFeatured =
    visibleItems.find((item) => item.id === catalog?.featuredId) ||
    visibleItems.find((item) => item.featured) ||
    visibleItems[0]
  featuredRotationItems = pickFeaturedRotationItems(visibleItems, primaryFeatured)
  featuredRotationIndex = Math.min(featuredRotationIndex, Math.max(0, featuredRotationItems.length - 1))

  if (appStoreFeatured) {
    renderFeaturedStoreCard(featuredRotationItems[featuredRotationIndex], featuredRotationItems)
  }

  renderCuratedStoreStrip(visibleItems, featuredRotationItems[featuredRotationIndex])

  if (storeMode === 'compact') {
    appStoreGrid.innerHTML = visibleItems
      .slice(0, 4)
      .map((item) => renderStoreCard(item, true))
      .join('')
  } else {
    const shelfItems = visibleItems.filter((item) => item.id !== featuredRotationItems[featuredRotationIndex]?.id)
    const sections = [...new Set((shelfItems.length ? shelfItems : visibleItems).map((item) => item.section || 'Catalog'))]

    appStoreGrid.innerHTML = sections
      .map((section) => {
        const sectionItems = (shelfItems.length ? shelfItems : visibleItems).filter(
          (item) => (item.section || 'Catalog') === section
        )
        const sectionMeta = storeSectionMeta[section] || {
          eyebrow: 'Install shelf',
          blurb: 'Install-ready content packs mirrored into the native RoachNet app.',
        }

        return `
          <section class="app-store-shelf" data-reveal>
            <div class="app-store-shelf__head">
              <div>
                <p class="app-store-shelf__eyebrow">${sectionMeta.eyebrow}</p>
                <h3>${section}</h3>
                <p class="app-store-shelf__summary">${sectionMeta.blurb}</p>
              </div>
              <span class="app-store-shelf__count">${sectionItems.length} picks</span>
            </div>
            <div class="app-store-shelf__grid">
              ${sectionItems.map((item) => renderStoreCard(item)).join('')}
            </div>
          </section>
        `
      })
      .join('')
  }

  if (appStoreUpdated) {
    const updated = catalog?.updatedAt ? new Date(catalog.updatedAt) : null
    appStoreUpdated.textContent =
      updated && !Number.isNaN(updated.valueOf())
        ? `Catalog updated ${new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(updated)}`
        : 'Catalog preview'
  }

  observeStoreReveals()
  startFeaturedRotation()
}

function renderAppDetailSheet(item) {
  const installUrl = buildInstallUrl(item)
  const detailUrl = item.detailUrl || item.primaryUrl
  const includes = (item.includes || []).map((line) => `<li>${line}</li>`).join('')

  return `
    <article class="app-detail-sheet__content" data-accent="${item.accent || 'blue'}">
      <div class="app-detail-sheet__hero">
        <div class="app-detail-sheet__icon">
          ${renderStoreIcon(item, 'detail')}
        </div>
        <div class="app-detail-sheet__copy">
          <p class="app-detail-sheet__eyebrow">${item.section} · ${item.category}</p>
          <h3 id="app-detail-title">${item.title}</h3>
          <p class="app-detail-sheet__subtitle">${item.subtitle || item.source}</p>
          <p class="app-detail-sheet__summary">${item.summary}</p>
          <div class="app-detail-sheet__meta">
            <span>${item.size}</span>
            <span>${item.status}</span>
            <span>${item.machineFit || item.source}</span>
          </div>
          <div class="app-detail-sheet__actions">
            ${
              installUrl
                ? `<a class="app-detail-sheet__primary" href="${installUrl}">${item.installLabel || 'Get'}</a>`
                : ''
            }
            ${
              detailUrl
                ? `<a class="app-detail-sheet__secondary" href="${detailUrl}">${item.detailLabel || 'View manifest'}</a>`
                : ''
            }
          </div>
        </div>
      </div>
      <div class="app-detail-sheet__body">
        <section>
          <h4>What installs</h4>
          <ul>${includes || '<li>RoachNet queues the selected content directly into the native install path.</li>'}</ul>
        </section>
        <section>
          <h4>Machine fit</h4>
          <p>${item.machineFit || 'Designed for the contained RoachNet install path on supported Macs.'}</p>
        </section>
        <section>
          <h4>Install behavior</h4>
          <p>Pressing Get opens the native app with a <code>roachnet://</code> handoff so the selected pack lands in the right module instead of downloading into a random folder.</p>
        </section>
      </div>
    </article>
  `
}

function openAppDetail(id) {
  const item = getCatalogItems().find((candidate) => candidate.id === id)
  if (!item || !appDetailOverlay || !appDetailContent) {
    return
  }

  appDetailContent.innerHTML = renderAppDetailSheet(item)
  appDetailOverlay.dataset.state = 'closed'
  appDetailOverlay.hidden = false
  requestAnimationFrame(() => {
    appDetailOverlay.dataset.state = 'open'
  })
  document.body.classList.add('app-detail-open')
}

function closeAppDetail() {
  if (!appDetailOverlay) {
    return
  }

  appDetailOverlay.dataset.state = 'closed'
  appDetailOverlay.hidden = true
  if (appDetailContent) {
    appDetailContent.innerHTML = ''
  }
  document.body.classList.remove('app-detail-open')
}

async function loadAppStoreCatalog() {
  if (!appStoreGrid) {
    return
  }

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

appStoreFilterBar?.addEventListener('click', (event) => {
  const filterButton = event.target.closest('[data-section-filter]')
  if (!filterButton) {
    return
  }

  appStoreActiveSection = filterButton.dataset.sectionFilter || 'All'
  featuredRotationIndex = 0
  renderAppStoreCatalog(appStoreCatalog || fallbackCatalog)
})

appStoreSearchInput?.addEventListener('input', (event) => {
  appStoreSearchQuery = event.currentTarget.value || ''
  featuredRotationIndex = 0
  renderAppStoreCatalog(appStoreCatalog || fallbackCatalog)
})

function handleAppStoreInteraction(event) {
  const previewButton = event.target.closest('[data-preview-id]')
  if (previewButton) {
    event.preventDefault()
    openAppDetail(previewButton.dataset.previewId)
    return
  }

  const featuredButton = event.target.closest('[data-featured-index]')
  if (featuredButton) {
    event.preventDefault()
    featuredRotationIndex = Number(featuredButton.dataset.featuredIndex || 0)
    renderFeaturedStoreCard(featuredRotationItems[featuredRotationIndex], featuredRotationItems)
    observeStoreReveals()
    startFeaturedRotation()
  }
}

appStoreGrid?.addEventListener('click', handleAppStoreInteraction)
appStoreFeatured?.addEventListener('click', handleAppStoreInteraction)
appStoreFeatured?.addEventListener('mouseenter', stopFeaturedRotation)
appStoreFeatured?.addEventListener('mouseleave', startFeaturedRotation)
appStoreFeatured?.addEventListener('focusin', stopFeaturedRotation)
appStoreFeatured?.addEventListener('focusout', startFeaturedRotation)

appDetailClose?.addEventListener('click', closeAppDetail)
appDetailOverlay?.addEventListener('click', (event) => {
  if (event.target === appDetailOverlay) {
    closeAppDetail()
  }
})

document.addEventListener('click', (event) => {
  const installLink = event.target.closest('a[href^="roachnet://install-content"]')
  if (!installLink) {
    return
  }

  event.preventDefault()
  attemptNativeInstall(installLink.getAttribute('href') || '')
})

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && appDetailOverlay && !appDetailOverlay.hidden) {
    event.preventDefault()
    closeAppDetail()
  }
})

closeAppDetail()
loadLatestRelease()
startHeroTelemetry()
loadAppStoreCatalog()
