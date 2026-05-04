const fs = require('node:fs')
const path = require('node:path')

const RELEASE_CHANNELS = ['stable', 'beta', 'alpha']
const APPLE_ACCELERATION_BACKENDS = ['auto', 'ollama', 'mlx']
const DISTRIBUTED_INFERENCE_BACKENDS = ['disabled', 'exo']
const EXO_NODE_ROLES = ['auto', 'coordinator', 'worker', 'hybrid']

const DEFAULT_CONFIG = {
  installPath: '',
  sourceMode: 'clone',
  sourceRepoUrl: 'https://github.com/RoachWares/RoachNet.git',
  sourceRef: 'main',
  autoInstallDependencies: true,
  installRoachClaw: true,
  roachClawDefaultModel: 'qwen2.5-coder:7b',
  installOptionalOllama: true,
  installOptionalOpenClaw: true,
  autoLaunch: true,
  dryRun: false,
  releaseChannel: 'stable',
  updateBaseUrl: '',
  autoCheckUpdates: true,
  autoDownloadUpdates: false,
  launchAtLogin: false,
  installOptionalMlx: false,
  appleAccelerationBackend: 'auto',
  mlxBaseUrl: 'http://127.0.0.1:8080',
  mlxModelId: '',
  distributedInferenceBackend: 'disabled',
  exoBaseUrl: 'http://127.0.0.1:52415',
  exoModelId: '',
  exoNodeRole: 'auto',
  exoAutoStart: false,
  installedAppPath: '',
  setupCompletedAt: null,
  pendingLaunchIntro: false,
  pendingRoachClawSetup: false,
  roachClawOnboardingCompletedAt: null,
  introCompletedAt: null,
  lastLaunchUrl: null,
  lastOpenedMode: 'auto',
  preferredShell: 'native',
}

function getConfigPath(app) {
  const sharedAppDataDir =
    app && typeof app.getPath === 'function'
      ? path.join(app.getPath('appData'), 'roachnet')
      : null

  return (
    process.env.ROACHNET_INSTALLER_CONFIG_PATH ||
    path.join(sharedAppDataDir || path.join(process.cwd(), '.roachnet'), 'roachnet-installer.json')
  )
}

function normalizeChannel(value) {
  return RELEASE_CHANNELS.includes(value) ? value : DEFAULT_CONFIG.releaseChannel
}

function normalizeUrl(value) {
  return typeof value === 'string' ? value.trim().replace(/\/+$/, '') : ''
}

function normalizeEnum(value, allowed, fallback) {
  return allowed.includes(value) ? value : fallback
}

function normalizeConfig(value = {}) {
  const installRoachClaw =
    value.installRoachClaw === undefined
      ? DEFAULT_CONFIG.installRoachClaw
      : Boolean(value.installRoachClaw)

  return {
    ...DEFAULT_CONFIG,
    ...value,
    releaseChannel: normalizeChannel(value.releaseChannel),
    updateBaseUrl: normalizeUrl(value.updateBaseUrl),
    mlxBaseUrl: normalizeUrl(value.mlxBaseUrl || DEFAULT_CONFIG.mlxBaseUrl),
    exoBaseUrl: normalizeUrl(value.exoBaseUrl || DEFAULT_CONFIG.exoBaseUrl),
    appleAccelerationBackend: normalizeEnum(
      value.appleAccelerationBackend,
      APPLE_ACCELERATION_BACKENDS,
      DEFAULT_CONFIG.appleAccelerationBackend
    ),
    distributedInferenceBackend: normalizeEnum(
      value.distributedInferenceBackend,
      DISTRIBUTED_INFERENCE_BACKENDS,
      DEFAULT_CONFIG.distributedInferenceBackend
    ),
    exoNodeRole: normalizeEnum(value.exoNodeRole, EXO_NODE_ROLES, DEFAULT_CONFIG.exoNodeRole),
    autoInstallDependencies:
      value.autoInstallDependencies === undefined
        ? DEFAULT_CONFIG.autoInstallDependencies
        : Boolean(value.autoInstallDependencies),
    installRoachClaw,
    roachClawDefaultModel:
      typeof value.roachClawDefaultModel === 'string' && value.roachClawDefaultModel.trim()
        ? value.roachClawDefaultModel.trim()
        : DEFAULT_CONFIG.roachClawDefaultModel,
    installOptionalOllama: installRoachClaw,
    installOptionalOpenClaw: installRoachClaw,
    installOptionalMlx: Boolean(value.installOptionalMlx),
    mlxModelId: typeof value.mlxModelId === 'string' ? value.mlxModelId.trim() : '',
    autoLaunch: value.autoLaunch === undefined ? DEFAULT_CONFIG.autoLaunch : Boolean(value.autoLaunch),
    dryRun: Boolean(value.dryRun),
    autoCheckUpdates:
      value.autoCheckUpdates === undefined
        ? DEFAULT_CONFIG.autoCheckUpdates
        : Boolean(value.autoCheckUpdates),
    autoDownloadUpdates: Boolean(value.autoDownloadUpdates),
    launchAtLogin: Boolean(value.launchAtLogin),
    exoModelId: typeof value.exoModelId === 'string' ? value.exoModelId.trim() : '',
    exoAutoStart: Boolean(value.exoAutoStart),
    installedAppPath: typeof value.installedAppPath === 'string' ? value.installedAppPath.trim() : '',
    pendingLaunchIntro: Boolean(value.pendingLaunchIntro),
    pendingRoachClawSetup: Boolean(value.pendingRoachClawSetup),
    roachClawOnboardingCompletedAt: value.roachClawOnboardingCompletedAt || null,
    introCompletedAt: value.introCompletedAt || null,
    preferredShell: 'native',
  }
}

function readConfig(app) {
  const configPath = getConfigPath(app)
  if (!fs.existsSync(configPath)) {
    return normalizeConfig()
  }

  try {
    return normalizeConfig(JSON.parse(fs.readFileSync(configPath, 'utf8')))
  } catch {
    return normalizeConfig()
  }
}

function writeConfig(app, updates = {}) {
  const configPath = getConfigPath(app)
  const nextConfig = normalizeConfig({
    ...readConfig(app),
    ...updates,
  })

  fs.mkdirSync(path.dirname(configPath), { recursive: true })
  fs.writeFileSync(configPath, JSON.stringify(nextConfig, null, 2) + '\n', 'utf8')
  return nextConfig
}

module.exports = {
  APPLE_ACCELERATION_BACKENDS,
  DEFAULT_CONFIG,
  DISTRIBUTED_INFERENCE_BACKENDS,
  EXO_NODE_ROLES,
  RELEASE_CHANNELS,
  getConfigPath,
  normalizeConfig,
  readConfig,
  writeConfig,
}
