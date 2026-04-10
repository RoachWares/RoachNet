/*
|--------------------------------------------------------------------------
| Routes file
|--------------------------------------------------------------------------
|
| The routes file is used for defining the HTTP routes.
|
*/
import router from '@adonisjs/core/services/router'
import type { HttpContext } from '@adonisjs/core/http'

const BenchmarkController = () => import('#controllers/benchmark_controller')
const ChatsController = () => import('#controllers/chats_controller')
const CollectionUpdatesController = () => import('#controllers/collection_updates_controller')
const CompanionController = () => import('#controllers/companion_controller')
const DocsController = () => import('#controllers/docs_controller')
const DownloadsController = () => import('#controllers/downloads_controller')
const EasySetupController = () => import('#controllers/easy_setup_controller')
const HomeController = () => import('#controllers/home_controller')
const MapsController = () => import('#controllers/maps_controller')
const OllamaController = () => import('#controllers/ollama_controller')
const OpenClawController = () => import('#controllers/openclaw_controller')
const RagController = () => import('#controllers/rag_controller')
const RoachClawController = () => import('#controllers/roachclaw_controller')
const SettingsController = () => import('#controllers/settings_controller')
const SiteArchivesController = () => import('#controllers/site_archives_controller')
const SystemController = () => import('#controllers/system_controller')
const ZimController = () => import('#controllers/zim_controller')

if (process.env.ROACHNET_DISABLE_TRANSMIT !== '1') {
  const { default: transmit } = await import('@adonisjs/transmit/services/main')
  transmit.registerRoutes()
}

router.get('/', [HomeController, 'index'])
router.get('/home', [HomeController, 'home'])
router.get('/about', async ({ inertia }: HttpContext) => inertia.render('about'))
router.get('/chat', [ChatsController, 'inertia'])
router.get('/maps', [MapsController, 'index'])
router.get('/site-archives', [SiteArchivesController, 'index'])
router.get('/site-archives/:slug/*', [SiteArchivesController, 'serve'])
router.on('/knowledge-base').redirectToPath('/chat?knowledge_base=true') // redirect for legacy knowledge-base links

router.get('/easy-setup', [EasySetupController, 'index'])
router.get('/easy-setup/complete', [EasySetupController, 'complete'])
router.get('/api/easy-setup/curated-categories', [EasySetupController, 'listCuratedCategories'])
router.post('/api/manifests/refresh', [EasySetupController, 'refreshManifests'])
router
  .group(() => {
    router.post('/check', [CollectionUpdatesController, 'checkForUpdates'])
    router.post('/apply', [CollectionUpdatesController, 'applyUpdate'])
    router.post('/apply-all', [CollectionUpdatesController, 'applyAllUpdates'])
  })
  .prefix('/api/content-updates')

router
  .group(() => {
    router.get('/ai', [SettingsController, 'ai'])
    router.get('/system', [SettingsController, 'system'])
    router.get('/apps', [SettingsController, 'apps'])
    router.get('/legal', [SettingsController, 'legal'])
    router.get('/maps', [SettingsController, 'maps'])
    router.get('/models', [SettingsController, 'models'])
    router.get('/update', [SettingsController, 'update'])
    router.get('/zim', [SettingsController, 'zim'])
    router.get('/zim/remote-explorer', [SettingsController, 'zimRemote'])
    router.get('/benchmark', [SettingsController, 'benchmark'])
    router.get('/support', [SettingsController, 'support'])
  })
  .prefix('/settings')

router
  .group(() => {
    router.get('/:slug', [DocsController, 'show'])
    router.get('/', ({ response }) => {
      // redirect to /docs/home if accessing root
      response.redirect('/docs/home')
    })
  })
  .prefix('/docs')

router
  .group(() => {
    router.get('/regions', [MapsController, 'listRegions'])
    router.get('/styles', [MapsController, 'styles'])
    router.get('/curated-collections', [MapsController, 'listCuratedCollections'])
    router.post('/fetch-latest-collections', [MapsController, 'fetchLatestCollections'])
    router.post('/download-base-assets', [MapsController, 'downloadBaseAssets'])
    router.post('/download-remote', [MapsController, 'downloadRemote'])
    router.post('/download-remote-preflight', [MapsController, 'downloadRemotePreflight'])
    router.post('/download-collection', [MapsController, 'downloadCollection'])
    router.delete('/:filename', [MapsController, 'delete'])
  })
  .prefix('/api/maps')

router
  .group(() => {
    router.get('/list', [DocsController, 'list'])
  })
  .prefix('/api/docs')

router
  .group(() => {
    router.get('/jobs', [DownloadsController, 'index'])
    router.get('/jobs/:filetype', [DownloadsController, 'filetype'])
    router.delete('/jobs/:jobId', [DownloadsController, 'removeJob'])
  })
  .prefix('/api/downloads')

router.get('/api/health', () => {
  if (process.env.ROACHNET_TRACE_REQUESTS === '1') {
    console.error('[roachnet:req] health:handler')
  }

  return { status: 'ok' }
})

router
  .group(() => {
    router.post('/chat', [OllamaController, 'chat'])
    router.get('/models', [OllamaController, 'availableModels'])
    router.post('/models', [OllamaController, 'dispatchModelDownload'])
    router.delete('/models', [OllamaController, 'deleteModel'])
    router.get('/installed-models', [OllamaController, 'installedModels'])
  })
  .prefix('/api/ollama')

router
  .group(() => {
    router.get('/skills/status', [OpenClawController, 'getSkillCliStatus'])
    router.get('/skills/search', [OpenClawController, 'searchSkills'])
    router.get('/skills/installed', [OpenClawController, 'listInstalledSkills'])
    router.post('/skills/install', [OpenClawController, 'installSkill'])
  })
  .prefix('/api/openclaw')

router
  .group(() => {
    router.get('/profile', [RoachClawController, 'getPortableProfile'])
    router.get('/status', [RoachClawController, 'getStatus'])
    router.post('/apply', [RoachClawController, 'apply'])
  })
  .prefix('/api/roachclaw')

router
  .group(() => {
    router.get('/', [SiteArchivesController, 'list'])
    router.post('/', [SiteArchivesController, 'create'])
    router.delete('/:slug', [SiteArchivesController, 'destroy'])
  })
  .prefix('/api/site-archives')

router
  .group(() => {
    router.get('/', [ChatsController, 'index'])
    router.post('/', [ChatsController, 'store'])
    router.delete('/all', [ChatsController, 'destroyAll'])
    router.get('/:id', [ChatsController, 'show'])
    router.put('/:id', [ChatsController, 'update'])
    router.delete('/:id', [ChatsController, 'destroy'])
    router.post('/:id/messages', [ChatsController, 'addMessage'])
  })
  .prefix('/api/chat/sessions')

router.get('/api/chat/suggestions', [ChatsController, 'suggestions'])

router
  .group(() => {
    router.get('/bootstrap', [CompanionController, 'bootstrap'])
    router.get('/runtime', [CompanionController, 'runtime'])
    router.get('/account', [CompanionController, 'account'])
    router.post('/account/affect', [CompanionController, 'affectAccount'])
    router.get('/roachtail', [CompanionController, 'roachtail'])
    router.post('/roachtail/pair', [CompanionController, 'pairRoachTail'])
    router.post('/roachtail/affect', [CompanionController, 'affectRoachTail'])
    router.get('/roachsync', [CompanionController, 'roachsync'])
    router.post('/roachsync/affect', [CompanionController, 'affectRoachSync'])
    router.get('/vault', [CompanionController, 'vault'])
    router.post('/services/affect', [CompanionController, 'affectService'])
    router.get('/chat/sessions', [CompanionController, 'sessionsIndex'])
    router.get('/chat/sessions/:id', [CompanionController, 'sessionsShow'])
    router.post('/chat/sessions', [CompanionController, 'sessionsStore'])
    router.post('/chat/send', [CompanionController, 'sendMessage'])
    router.post('/install', [CompanionController, 'install'])
  })
  .prefix('/api/companion')

router
  .group(() => {
    router.post('/upload', [RagController, 'upload'])
    router.get('/files', [RagController, 'getStoredFiles'])
    router.delete('/files', [RagController, 'deleteFile'])
    router.get('/active-jobs', [RagController, 'getActiveJobs'])
    router.get('/job-status', [RagController, 'getJobStatus'])
    router.post('/sync', [RagController, 'scanAndSync'])
  })
  .prefix('/api/rag')

router
  .group(() => {
    router.get('/debug-info', [SystemController, 'getDebugInfo'])
    router.get('/info', [SystemController, 'getSystemInfo'])
    router.get('/internet-status', [SystemController, 'getInternetStatus'])
    router.get('/services', [SystemController, 'getServices'])
    router.get('/ai/providers', [SystemController, 'getAIRuntimeProviders'])
    router.get('/native-snapshot', [SystemController, 'getNativeSnapshot'])
    router.post('/services/affect', [SystemController, 'affectService'])
    router.post('/services/install', [SystemController, 'installService'])
    router.post('/services/force-reinstall', [SystemController, 'forceReinstallService'])
    router.post('/services/check-updates', [SystemController, 'checkServiceUpdates'])
    router.get('/services/:name/available-versions', [SystemController, 'getAvailableVersions'])
    router.post('/services/update', [SystemController, 'updateService'])
    router.post('/subscribe-release-notes', [SystemController, 'subscribeToReleaseNotes'])
    router.get('/latest-version', [SystemController, 'checkLatestVersion'])
    router.post('/update', [SystemController, 'requestSystemUpdate'])
    router.get('/update/status', [SystemController, 'getSystemUpdateStatus'])
    router.get('/update/logs', [SystemController, 'getSystemUpdateLogs'])
    router.get('/upstream-sync/status', [SystemController, 'getUpstreamSyncStatus'])
    router.post('/upstream-sync', [SystemController, 'requestUpstreamSync'])
    router.get('/upstream-sync/logs', [SystemController, 'getUpstreamSyncLogs'])
    router.get('/settings', [SettingsController, 'getSetting'])
    router.patch('/settings', [SettingsController, 'updateSetting'])
  })
  .prefix('/api/system')

router
  .group(() => {
    router.get('/list', [ZimController, 'list'])
    router.get('/list-remote', [ZimController, 'listRemote'])
    router.get('/curated-categories', [ZimController, 'listCuratedCategories'])
    router.post('/download-remote', [ZimController, 'downloadRemote'])
    router.post('/download-category-tier', [ZimController, 'downloadCategoryTier'])
    router.post('/download-category-resource', [ZimController, 'downloadCategoryResource'])

    router.get('/wikipedia', [ZimController, 'getWikipediaState'])
    router.post('/wikipedia/select', [ZimController, 'selectWikipedia'])
    router.delete('/:filename', [ZimController, 'delete'])
  })
  .prefix('/api/zim')

router
  .group(() => {
    router.post('/run', [BenchmarkController, 'run'])
    router.post('/run/system', [BenchmarkController, 'runSystem'])
    router.post('/run/ai', [BenchmarkController, 'runAI'])
    router.get('/results', [BenchmarkController, 'results'])
    router.get('/results/latest', [BenchmarkController, 'latest'])
    router.get('/results/:id', [BenchmarkController, 'show'])
    router.post('/submit', [BenchmarkController, 'submit'])
    router.post('/builder-tag', [BenchmarkController, 'updateBuilderTag'])
    router.get('/comparison', [BenchmarkController, 'comparison'])
    router.get('/status', [BenchmarkController, 'status'])
    router.get('/settings', [BenchmarkController, 'settings'])
    router.post('/settings', [BenchmarkController, 'updateSettings'])
  })
  .prefix('/api/benchmark')
