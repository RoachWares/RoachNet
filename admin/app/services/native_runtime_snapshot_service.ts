import { inject } from '@adonisjs/core'
import logger from '@adonisjs/core/services/logger'
import { AIRuntimeService } from '#services/ai_runtime_service'
import { DownloadService } from '#services/download_service'
import { MapService } from '#services/map_service'
import { OllamaService } from '#services/ollama_service'
import { OpenClawService } from '#services/openclaw_service'
import { RagService } from '#services/rag_service'
import { RoachClawService } from '#services/roachclaw_service'
import { SiteArchiveService } from '#services/site_archive_service'
import { SystemService } from '#services/system_service'
import { ZimService } from '#services/zim_service'
import type { SystemInformationResponse } from '../../types/system.js'

type NativeRuntimeSnapshot = {
  capturedAt: string
  internetConnected: boolean
  systemInfo: SystemInformationResponse
  services: Awaited<ReturnType<SystemService['getServices']>>
  downloads: Awaited<ReturnType<DownloadService['listDownloadJobs']>>
  providers: Awaited<ReturnType<AIRuntimeService['getProviders']>>
  roachClaw: Awaited<ReturnType<RoachClawService['getStatus']>>
  installedModels: Awaited<ReturnType<OllamaService['getModels']>>
  installedSkills: Awaited<ReturnType<OpenClawService['getInstalledSkills']>>['skills']
  knowledgeFiles: Awaited<ReturnType<RagService['getStoredFiles']>>
  mapCollections: Awaited<ReturnType<MapService['listCuratedCollections']>>
  educationCategories: Awaited<ReturnType<ZimService['listCuratedCategories']>>
  wikipediaState: Awaited<ReturnType<ZimService['getWikipediaState']>>
  siteArchives: Awaited<ReturnType<SiteArchiveService['listArchives']>>
}

@inject()
export class NativeRuntimeSnapshotService {
  private cache: { value: NativeRuntimeSnapshot; expiresAt: number } | null = null
  private inflightSnapshot: Promise<NativeRuntimeSnapshot> | null = null
  private static readonly CACHE_TTL_MS = 3000

  constructor(
    private systemService: SystemService,
    private aiRuntimeService: AIRuntimeService,
    private roachClawService: RoachClawService,
    private ollamaService: OllamaService,
    private openClawService: OpenClawService,
    private downloadService: DownloadService,
    private ragService: RagService,
    private mapService: MapService,
    private zimService: ZimService,
    private siteArchiveService: SiteArchiveService
  ) {}

  async getSnapshot(): Promise<NativeRuntimeSnapshot> {
    const now = Date.now()
    if (this.cache && this.cache.expiresAt > now) {
      return this.cache.value
    }

    if (!this.inflightSnapshot) {
      this.inflightSnapshot = this.buildSnapshot()
        .then((snapshot) => {
          this.cache = {
            value: snapshot,
            expiresAt: Date.now() + NativeRuntimeSnapshotService.CACHE_TTL_MS,
          }
          return snapshot
        })
        .finally(() => {
          this.inflightSnapshot = null
        })
    }

    return this.inflightSnapshot
  }

  private async buildSnapshot(): Promise<NativeRuntimeSnapshot> {
    const [internetConnected, systemInfo, services, providers, roachClaw] = await Promise.all([
      this.safe('internet status', () => this.systemService.getInternetStatus(), false, 2000),
      this.safe('system info', () => this.systemService.getSystemInfo(), this.getFallbackSystemInfo(), 3000),
      this.safe('services', () => this.systemService.getServices({ installedOnly: false }), [], 3000),
      this.safe('AI providers', () => this.aiRuntimeService.getProviders(), this.getFallbackProviders(), 2500),
      this.safe('RoachClaw status', () => this.roachClawService.getStatus(), this.getFallbackRoachClaw(), 3000),
    ])

    return {
      capturedAt: new Date().toISOString(),
      internetConnected,
      systemInfo: systemInfo ?? this.getFallbackSystemInfo(),
      services,
      downloads: await this.safe('download jobs', () => this.downloadService.listDownloadJobs(), []),
      providers,
      roachClaw,
      installedModels: await this.safe('installed Ollama models', () => this.ollamaService.getModels(), []),
      installedSkills: await this.safe('installed OpenClaw skills', async () => {
        const { skills } = await this.openClawService.getInstalledSkills()
        return skills
      }, []),
      knowledgeFiles: await this.safe('knowledge files', () => this.ragService.getStoredFiles(), []),
      mapCollections: await this.safe('map collections', () => this.mapService.listCuratedCollections(), []),
      educationCategories: await this.safe(
        'education categories',
        () => this.zimService.listCuratedCategories(),
        []
      ),
      wikipediaState: await this.safe(
        'wikipedia state',
        () => this.zimService.getWikipediaState(),
        { options: [], currentSelection: null }
      ),
      siteArchives: await this.safe('site archives', () => this.siteArchiveService.listArchives(), []),
    }
  }

  private async safe<T>(
    label: string,
    operation: () => Promise<T>,
    fallback: T,
    timeoutMs = 2500
  ): Promise<T> {
    let timeoutHandle: ReturnType<typeof setTimeout> | undefined

    try {
      return await Promise.race([
        operation(),
        new Promise<T>((resolve) => {
          timeoutHandle = setTimeout(() => {
            logger.warn(`[NativeRuntimeSnapshotService] Timed out while resolving ${label}; using fallback.`)
            resolve(fallback)
          }, timeoutMs)
        }),
      ])
    } catch (error) {
      logger.warn(
        `[NativeRuntimeSnapshotService] Falling back for ${label}: ${error instanceof Error ? error.message : String(error)}`
      )
      return fallback
    } finally {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }
    }
  }

  private getFallbackProviders(): NativeRuntimeSnapshot['providers'] {
    return {
      providers: {
        ollama: {
          provider: 'ollama',
          available: false,
          source: 'none',
          baseUrl: null,
          error: 'Ollama runtime is still warming up.',
        },
        openclaw: {
          provider: 'openclaw',
          available: false,
          source: 'none',
          baseUrl: null,
          error: 'OpenClaw runtime is still warming up.',
        },
      },
    }
  }

  private getFallbackRoachClaw(): NativeRuntimeSnapshot['roachClaw'] {
    const providers = this.getFallbackProviders().providers
    return {
      label: 'RoachClaw',
      ollama: providers.ollama,
      openclaw: providers.openclaw,
      cliStatus: {
        openclawAvailable: false,
        clawhubAvailable: false,
        workspacePath: '',
        runner: 'none',
      },
      workspacePath: '',
      defaultModel: null,
      resolvedDefaultModel: null,
      preferredMode: 'offline',
      ready: false,
      installedModels: [],
      preferredModels: [],
      configFilePath: null,
    }
  }

  private getFallbackSystemInfo(): SystemInformationResponse {
    return {
      cpu: {
        manufacturer: 'Unknown',
        brand: 'Unavailable',
        physicalCores: 0,
        cores: 0,
      } as SystemInformationResponse['cpu'],
      mem: {
        total: 0,
        available: 0,
        swapused: 0,
      } as SystemInformationResponse['mem'],
      os: {
        hostname: 'roachnet',
        arch: process.arch,
        distro: 'Unavailable',
      } as SystemInformationResponse['os'],
      disk: [],
      currentLoad: {
        currentLoad: 0,
      } as SystemInformationResponse['currentLoad'],
      fsSize: [],
      uptime: {
        uptime: 0,
      } as SystemInformationResponse['uptime'],
      graphics: {
        controllers: [],
        displays: [],
      } as SystemInformationResponse['graphics'],
      gpuHealth: {
        status: 'no_gpu',
        hasNvidiaRuntime: false,
        ollamaGpuAccessible: false,
      },
      hardwareProfile: {
        platformLabel: 'Unavailable',
        chipFamily: 'generic',
        isAppleSilicon: false,
        memoryTier: 'balanced',
        recommendedRuntime: 'native_local',
        recommendedModelClass: 'small',
        notes: [],
        warnings: ['System information is still warming up.'],
      },
    }
  }
}
