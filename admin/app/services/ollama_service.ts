import { inject } from '@adonisjs/core'
import { ChatRequest, Ollama, type ListResponse } from 'ollama'
import { RoachNetOllamaModel } from '../../types/ollama.js'
import { FALLBACK_RECOMMENDED_OLLAMA_MODELS } from '../../constants/ollama.js'
import fs from 'node:fs/promises'
import path from 'node:path'
import logger from '@adonisjs/core/services/logger'
import axios from 'axios'
import { DownloadModelJob } from '#jobs/download_model_job'
import { SERVICE_NAMES } from '../../constants/service_names.js'
import Fuse, { IFuseOptions } from 'fuse.js'
import { BROADCAST_CHANNELS } from '../../constants/broadcast.js'
import env from '#start/env'
import { ROACHNET_API_DEFAULT_BASE_URL } from '../../constants/misc.js'
import type { AIRuntimeSource, AIRuntimeStatus } from '../../types/ai.js'
import KVStore from '#models/kv_store'
import { broadcastTransmit } from '#services/transmit_bridge'

const ROACHNET_MODELS_API_PATH = '/api/v1/ollama/models'
const MODELS_CACHE_FILE = path.join(process.cwd(), 'storage', 'ollama-models-cache.json')
const CACHE_MAX_AGE_MS = 24 * 60 * 60 * 1000 // 24 hours
const DEFAULT_OLLAMA_BASE_URL = 'http://127.0.0.1:11434'
const DEFAULT_DASHSCOPE_BASE_URL = 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1'

type CloudChatResponse = {
  id?: string
  created?: number
  choices?: Array<{
    message?: {
      role?: string
      content?: string
    }
  }>
}

class CloudInferenceService {
  private static readonly SYNTHETIC_MODELS = [
    {
      alias: 'qwen-plus:cloud',
      providerModel: 'qwen-plus',
      size: 0,
    },
  ] as const
  private availabilityCache: { value: boolean; expiresAt: number } | null = null

  public isCloudModel(modelName: string): boolean {
    return modelName.trim().toLowerCase().endsWith(':cloud')
  }

  public async listModels(): Promise<ListResponse['models']> {
    if (!(await this.isAvailable())) {
      return []
    }

    return CloudInferenceService.SYNTHETIC_MODELS.map((entry) => ({
      name: entry.alias,
      model: entry.alias,
      size: entry.size,
      digest: 'cloud',
      modified_at: new Date(0).toISOString(),
      details: {
        family: 'cloud',
        families: ['cloud'],
        format: 'remote',
        parameter_size: 'cloud',
        quantization_level: 'remote',
      },
      expires_at: new Date(0).toISOString(),
      size_vram: 0,
    })) as unknown as ListResponse['models']
  }

  public async chat(chatRequest: ChatRequest & { stream?: boolean }) {
    if (!(await this.isAvailable())) {
      throw new Error('RoachNet cloud chat is not configured.')
    }

    const resolvedModel = this.resolveModelAlias(chatRequest.model)
    if (!resolvedModel) {
      throw new Error(`Unsupported RoachNet cloud model: ${chatRequest.model}`)
    }

    const response = await axios.post<CloudChatResponse>(
      `${this.getBaseUrl()}/chat/completions`,
      {
        model: resolvedModel.providerModel,
        messages: chatRequest.messages,
        stream: false,
      },
      {
        timeout: 45_000,
        headers: {
          Authorization: `Bearer ${this.getApiKey()}`,
          'Content-Type': 'application/json',
        },
        validateStatus: () => true,
      }
    )

    if (response.status < 200 || response.status >= 300) {
      throw new Error(`RoachNet cloud chat returned HTTP ${response.status}.`)
    }

    const content = response.data?.choices?.[0]?.message?.content?.trim()
    if (!content) {
      throw new Error('RoachNet cloud chat returned an empty response.')
    }

    return {
      model: chatRequest.model,
      created_at: new Date(
        typeof response.data?.created === 'number' ? response.data.created * 1000 : Date.now()
      ).toISOString(),
      message: {
        role: response.data?.choices?.[0]?.message?.role ?? 'assistant',
        content,
      },
      done: true,
    }
  }

  private resolveModelAlias(modelName: string) {
    return CloudInferenceService.SYNTHETIC_MODELS.find((entry) => entry.alias === modelName.trim())
  }

  private async isAvailable(): Promise<boolean> {
    const apiKey = this.getApiKey()
    if (!apiKey) {
      return false
    }

    const now = Date.now()
    if (this.availabilityCache && this.availabilityCache.expiresAt > now) {
      return this.availabilityCache.value
    }

    try {
      const response = await axios.get(`${this.getBaseUrl()}/models`, {
        timeout: 6_000,
        headers: {
          Authorization: `Bearer ${apiKey}`,
        },
        validateStatus: () => true,
      })

      const isHealthy = response.status >= 200 && response.status < 300
      this.availabilityCache = {
        value: isHealthy,
        expiresAt: now + 60_000,
      }
      return isHealthy
    } catch {
      this.availabilityCache = {
        value: false,
        expiresAt: now + 30_000,
      }
      return false
    }
  }

  private getApiKey(): string {
    return process.env.DASHSCOPE_API_KEY?.trim() || ''
  }

  private getBaseUrl(): string {
    return process.env.DASHSCOPE_BASE_URL?.trim() || DEFAULT_DASHSCOPE_BASE_URL
  }
}

@inject()
export class OllamaService {
  private static runtimeStatusCache:
    | { value: AIRuntimeStatus; expiresAt: number }
    | null = null
  private static runtimeStatusInflight: Promise<AIRuntimeStatus> | null = null
  private static modelsCache = new Map<string, { value: Awaited<ReturnType<OllamaService['getModels']>>; expiresAt: number }>()
  private static modelsInflight = new Map<string, Promise<Awaited<ReturnType<OllamaService['getModels']>>>>()
  private static readonly RUNTIME_STATUS_CACHE_TTL_MS = 3000
  private static readonly MODELS_CACHE_TTL_MS = 5000
  private static readonly RUNTIME_PROBE_TIMEOUT_MS = 1500
  private ollama: Ollama | null = null
  private ollamaInitPromise: Promise<void> | null = null
  private ollamaHost: string | null = null
  private ollamaConfigFingerprint: string | null = null
  private cloudInference = new CloudInferenceService()

  constructor() { }

  private getModelsListTimeoutMs(): number {
    return process.env.ROACHNET_NATIVE_ONLY === '1' ? 4_000 : 12_000
  }

  private async _initializeOllamaClient() {
    if (!this.ollamaInitPromise) {
      this.ollamaInitPromise = (async () => {
        const runtimeStatus = await this.getRuntimeStatus()
        if (!runtimeStatus.available || !runtimeStatus.baseUrl) {
          throw new Error(runtimeStatus.error || 'Ollama service is not installed or running.')
        }

        if (!this.ollama || this.ollamaHost !== runtimeStatus.baseUrl) {
          this.ollamaHost = runtimeStatus.baseUrl
          this.ollama = new Ollama({ host: runtimeStatus.baseUrl })
        }
        this.ollamaConfigFingerprint = await this.getConfigFingerprint()
      })().catch((error) => {
        this.ollama = null
        this.ollamaHost = null
        this.ollamaConfigFingerprint = null
        this.ollamaInitPromise = null
        throw error
      })
    }
    return this.ollamaInitPromise
  }

  private async _ensureDependencies() {
    const configFingerprint = await this.getConfigFingerprint()
    if (this.ollama && this.ollamaConfigFingerprint !== configFingerprint) {
      this.ollama = null
      this.ollamaHost = null
      this.ollamaInitPromise = null
      this.ollamaConfigFingerprint = null
      this.clearRuntimeCaches()
    }

    if (!this.ollama) {
      await this._initializeOllamaClient()
    }
  }

  private async getConfigFingerprint(): Promise<string> {
    const settingUrl = await this.readConfiguredOllamaBaseUrl()
    const configuredUrl = env.get('OLLAMA_BASE_URL')?.trim()
    const preferredUrl =
      process.env.ROACHNET_NATIVE_ONLY === '1'
        ? configuredUrl || settingUrl || '__auto__'
        : settingUrl || configuredUrl || '__auto__'
    return this.normalizeBaseUrl(preferredUrl)
  }

  private clearRuntimeCaches() {
    OllamaService.runtimeStatusCache = null
    OllamaService.modelsCache.clear()
    OllamaService.modelsInflight.clear()
  }

  /**
   * Downloads a model from the Ollama service with progress tracking. Where possible,
   * one should dispatch a background job instead of calling this method directly to avoid long blocking.
   * @param model Model name to download
   * @returns Success status and message
   */
  async downloadModel(model: string, progressCallback?: (percent: number) => void): Promise<{ success: boolean; message: string; retryable?: boolean }> {
    try {
      await this._ensureDependencies()
      if (!this.ollama) {
        throw new Error('Ollama client is not initialized.')
      }

      // Try to avoid duplicate pulls, but don't abort first-boot onboarding if listing is still warming up.
      try {
        const installedModels = await this.getModels()
        if (installedModels.some((m) => m.name === model)) {
          logger.info(`[OllamaService] Model "${model}" is already installed.`)
          return { success: true, message: 'Model is already installed.' }
        }
      } catch (error) {
        logger.warn(
          `[OllamaService] Continuing with pull for "${model}" after model list probe failed: ${
            error instanceof Error ? error.message : error
          }`
        )
      }

      // Returns AbortableAsyncIterator<ProgressResponse>
      const downloadStream = await this.ollama.pull({
        model,
        stream: true,
      })

      for await (const chunk of downloadStream) {
        if (chunk.completed && chunk.total) {
          const percent = ((chunk.completed / chunk.total) * 100).toFixed(2)
          const percentNum = parseFloat(percent)

          this.broadcastDownloadProgress(model, percentNum)
          if (progressCallback) {
            progressCallback(percentNum)
          }
        }
      }

      logger.info(`[OllamaService] Model "${model}" downloaded successfully.`)
      this.clearRuntimeCaches()
      return { success: true, message: 'Model downloaded successfully.' }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error)
      logger.error(
        `[OllamaService] Failed to download model "${model}": ${errorMessage}`
      )

      // Check for version mismatch (Ollama 412 response)
      const isVersionMismatch = errorMessage.includes('newer version of Ollama')
      const userMessage = isVersionMismatch
        ? 'This model requires a newer version of Ollama. Please update AI Assistant from the Apps page.'
        : `Failed to download model: ${errorMessage}`

      // Broadcast failure to connected clients so UI can show the error
      this.broadcastDownloadError(model, userMessage)

      return { success: false, message: userMessage, retryable: !isVersionMismatch }
    }
  }

  async dispatchModelDownload(modelName: string): Promise<{ success: boolean; message: string }> {
    try {
      logger.info(`[OllamaService] Dispatching model download for ${modelName} via job queue`)

      await DownloadModelJob.dispatch({
        modelName,
      })

      return {
        success: true,
        message:
          'Model download has been queued successfully. It will start shortly after Ollama and Open WebUI are ready (if not already).',
      }
    } catch (error) {
      logger.error(
        `[OllamaService] Failed to dispatch model download for ${modelName}: ${error instanceof Error ? error.message : error}`
      )
      return {
        success: false,
        message: 'Failed to queue model download. Please try again.',
      }
    }
  }

  public async getClient() {
    await this._ensureDependencies()
    return this.ollama!
  }

  public async getRuntimeStatus(): Promise<AIRuntimeStatus> {
    const now = Date.now()
    if (
      OllamaService.runtimeStatusCache &&
      OllamaService.runtimeStatusCache.expiresAt > now
    ) {
      return OllamaService.runtimeStatusCache.value
    }

    if (OllamaService.runtimeStatusInflight) {
      return OllamaService.runtimeStatusInflight
    }

    OllamaService.runtimeStatusInflight = this.resolveRuntimeStatus()
      .then((runtimeStatus) => {
        OllamaService.runtimeStatusCache = {
          value: runtimeStatus,
          expiresAt: Date.now() + OllamaService.RUNTIME_STATUS_CACHE_TTL_MS,
        }
        return runtimeStatus
      })
      .finally(() => {
        OllamaService.runtimeStatusInflight = null
      })

    return OllamaService.runtimeStatusInflight
  }

  private async resolveRuntimeStatus(): Promise<AIRuntimeStatus> {
    let lastRuntimeStatus: AIRuntimeStatus | null = null
    let preferredOfflineStatus: AIRuntimeStatus | null = null

    const primaryCandidates = await this.getPrimaryRuntimeCandidates()

    for (const candidate of primaryCandidates) {
      const runtimeStatus = await this.checkRuntimeCandidate(candidate.baseUrl, candidate.source)
      if (runtimeStatus.available) {
        return runtimeStatus
      }

      if (!preferredOfflineStatus && candidate.source === 'configured') {
        preferredOfflineStatus = runtimeStatus
      }
      lastRuntimeStatus = runtimeStatus
    }

    const dockerCandidate = await this.getDockerRuntimeCandidate()
    if (dockerCandidate) {
      const dockerRuntimeStatus = await this.checkRuntimeCandidate(
        dockerCandidate.baseUrl,
        dockerCandidate.source
      )
      if (dockerRuntimeStatus.available) {
        return dockerRuntimeStatus
      }

      lastRuntimeStatus = dockerRuntimeStatus
    }

    if (preferredOfflineStatus) {
      return preferredOfflineStatus
    }

    if (lastRuntimeStatus) {
      return lastRuntimeStatus
    }

    return {
      provider: 'ollama',
      available: false,
      source: 'none',
      baseUrl: null,
      error: 'Ollama runtime is not available.',
    }
  }

  public async chat(chatRequest: ChatRequest & { stream?: boolean }) {
    if (this.isCloudModel(chatRequest.model)) {
      return await this.cloudInference.chat(chatRequest)
    }

    await this._ensureDependencies()
    if (!this.ollama) {
      throw new Error('Ollama client is not initialized.')
    }
    return await this.ollama.chat({
      ...chatRequest,
      stream: false,
    })
  }

  public async chatStream(chatRequest: ChatRequest) {
    if (this.isCloudModel(chatRequest.model)) {
      throw new Error('Streaming is not available for RoachNet cloud chat yet.')
    }

    await this._ensureDependencies()
    if (!this.ollama) {
      throw new Error('Ollama client is not initialized.')
    }
    return await this.ollama.chat({
      ...chatRequest,
      stream: true,
    })
  }

  public async checkModelHasThinking(modelName: string): Promise<boolean> {
    await this._ensureDependencies()
    if (!this.ollama) {
      throw new Error('Ollama client is not initialized.')
    }

    const modelInfo = await this.ollama.show({
      model: modelName,
    })

    return modelInfo.capabilities.includes('thinking')
  }

  public async deleteModel(modelName: string) {
    await this._ensureDependencies()
    if (!this.ollama) {
      throw new Error('Ollama client is not initialized.')
    }

    const result = await this.ollama.delete({
      model: modelName,
    })
    this.clearRuntimeCaches()
    return result
  }

  public async getModels(includeEmbeddings = false) {
    const cacheKey = includeEmbeddings ? 'all' : 'default'
    const now = Date.now()
    const cachedEntry = OllamaService.modelsCache.get(cacheKey)
    if (cachedEntry && cachedEntry.expiresAt > now) {
      return cachedEntry.value
    }

    const inflightEntry = OllamaService.modelsInflight.get(cacheKey)
    if (inflightEntry) {
      return inflightEntry
    }

    const promise = this.fetchModels(includeEmbeddings)
      .then((models) => {
        OllamaService.modelsCache.set(cacheKey, {
          value: models,
          expiresAt: Date.now() + OllamaService.MODELS_CACHE_TTL_MS,
        })
        return models
      })
      .finally(() => {
        OllamaService.modelsInflight.delete(cacheKey)
      })

    OllamaService.modelsInflight.set(cacheKey, promise)
    return promise
  }

  private async fetchModels(includeEmbeddings: boolean) {
    const cloudModels = await this.cloudInference.listModels()
    let models: ListResponse['models'] = []
    let localError: unknown = null

    try {
      await this._ensureDependencies()
      if (!this.ollama) {
        throw new Error('Ollama client is not initialized.')
      }

      const runtimeStatus = await this.getRuntimeStatus()
      const shouldPreferHttpListing =
        runtimeStatus.available &&
        (process.env.ROACHNET_NATIVE_ONLY === '1' ||
          runtimeStatus.source === 'configured' ||
          runtimeStatus.source === 'docker')

      if (shouldPreferHttpListing) {
        try {
          models = await this.fetchModelsViaHttp(runtimeStatus)
        } catch (error) {
          logger.warn(
            `[OllamaService] Falling back to ollama.list after direct /api/tags lookup failed: ${
              error instanceof Error ? error.message : error
            }`
          )
          const response = await this.withTimeout(
            'ollama.list',
            () => this.ollama!.list(),
            this.getModelsListTimeoutMs()
          )
          models = response.models
        }
      } else {
        try {
          const response = await this.withTimeout(
            'ollama.list',
            () => this.ollama!.list(),
            this.getModelsListTimeoutMs()
          )
          models = response.models
        } catch (error) {
          logger.warn(
            `[OllamaService] Falling back to direct /api/tags lookup after ollama.list failed: ${
              error instanceof Error ? error.message : error
            }`
          )
          models = await this.fetchModelsViaHttp(runtimeStatus)
        }
      }
    } catch (error) {
      localError = error
      logger.warn(
        `[OllamaService] Falling back to the RoachNet cloud catalog after local model discovery failed: ${
          error instanceof Error ? error.message : error
        }`
      )
    }

    if (cloudModels.length > 0) {
      const knownModels = new Set(models.map((model) => model.name))
      for (const cloudModel of cloudModels) {
        if (!knownModels.has(cloudModel.name)) {
          models.push(cloudModel)
        }
      }
    }

    if (models.length === 0 && localError) {
      throw localError
    }

    if (includeEmbeddings) {
      return models
    }

    return models.filter((model) => !model.name.includes('embed'))
  }

  private async fetchModelsViaHttp(runtimeStatus?: AIRuntimeStatus): Promise<ListResponse['models']> {
    const resolvedRuntimeStatus = runtimeStatus ?? await this.getRuntimeStatus()
    if (!resolvedRuntimeStatus.available || !resolvedRuntimeStatus.baseUrl) {
      throw new Error(resolvedRuntimeStatus.error || 'Ollama runtime is not available.')
    }

    const response = await axios.get(this.buildRuntimeUrl(resolvedRuntimeStatus.baseUrl, '/api/tags'), {
      timeout: this.getModelsListTimeoutMs(),
      validateStatus: () => true,
    })

    if (response.status < 200 || response.status >= 300) {
      throw new Error(`Ollama runtime at ${resolvedRuntimeStatus.baseUrl} returned HTTP ${response.status}.`)
    }

    if (!response.data || !Array.isArray(response.data.models)) {
      throw new Error('Ollama runtime returned an invalid model list payload.')
    }

    return response.data.models as ListResponse['models']
  }

  async getAvailableModels(
    { sort, recommendedOnly, query, limit, force }: { sort?: 'pulls' | 'name'; recommendedOnly?: boolean, query: string | null, limit?: number, force?: boolean } = {
      sort: 'pulls',
      recommendedOnly: false,
      query: null,
      limit: 15,
    }
  ): Promise<{ models: RoachNetOllamaModel[], hasMore: boolean } | null> {
    try {
      const models = await this.retrieveAndRefreshModels(sort, force)
      if (!models) {
        // If we fail to get models from the API, return the fallback recommended models
        logger.warn(
          '[OllamaService] Returning fallback recommended models due to failure in fetching available models'
        )
        return {
          models: FALLBACK_RECOMMENDED_OLLAMA_MODELS,
          hasMore: false
        }
      }

      if (!recommendedOnly) {
        const filteredModels = query ? this.fuseSearchModels(models, query) : models
        return {
          models: filteredModels.slice(0, limit || 15),
          hasMore: filteredModels.length > (limit || 15)
        }
      }

      // If recommendedOnly is true, only return the first three models (if sorted by pulls, these will be the top 3)
      const sortedByPulls = sort === 'pulls' ? models : this.sortModels(models, 'pulls')
      const firstThree = sortedByPulls.slice(0, 3)

      // Only return the first tag of each of these models (should be the most lightweight variant)
      const recommendedModels = firstThree.map((model) => {
        return {
          ...model,
          tags: model.tags && model.tags.length > 0 ? [model.tags[0]] : [],
        }
      })

      if (query) {
        const filteredRecommendedModels = this.fuseSearchModels(recommendedModels, query)
        return {
          models: filteredRecommendedModels,
          hasMore: filteredRecommendedModels.length > (limit || 15)
        }
      }

      return {
        models: recommendedModels,
        hasMore: recommendedModels.length > (limit || 15)
      }
    } catch (error) {
      logger.error(
        `[OllamaService] Failed to get available models: ${error instanceof Error ? error.message : error}`
      )
      return null
    }
  }

  private async retrieveAndRefreshModels(
    sort?: 'pulls' | 'name',
    force?: boolean
  ): Promise<RoachNetOllamaModel[] | null> {
    try {
      if (!force) {
        const cachedModels = await this.readModelsFromCache()
        if (cachedModels) {
          logger.info('[OllamaService] Using cached available models data')
          return this.sortModels(cachedModels, sort)
        }
      } else {
        logger.info('[OllamaService] Force refresh requested, bypassing cache')
      }

      logger.info('[OllamaService] Fetching fresh available models from API')

      const baseUrl = env.get('ROACHNET_API_URL') || ROACHNET_API_DEFAULT_BASE_URL
      const fullUrl = new URL(ROACHNET_MODELS_API_PATH, baseUrl).toString()

      const response = await axios.get(fullUrl)
      if (!response.data || !Array.isArray(response.data.models)) {
        logger.warn(
          `[OllamaService] Invalid response format when fetching available models: ${JSON.stringify(response.data)}`
        )
        return null
      }

      const rawModels = response.data.models as RoachNetOllamaModel[]

      // Filter out tags where cloud is truthy, then remove models with no remaining tags
      const noCloud = rawModels
        .map((model) => ({
          ...model,
          tags: model.tags.filter((tag) => !tag.cloud),
        }))
        .filter((model) => model.tags.length > 0)

      await this.writeModelsToCache(noCloud)
      return this.sortModels(noCloud, sort)
    } catch (error) {
      logger.error(
        `[OllamaService] Failed to retrieve models from RoachNet API: ${error instanceof Error ? error.message : error
        }`
      )
      return null
    }
  }

  private async readModelsFromCache(): Promise<RoachNetOllamaModel[] | null> {
    try {
      const stats = await fs.stat(MODELS_CACHE_FILE)
      const cacheAge = Date.now() - stats.mtimeMs

      if (cacheAge > CACHE_MAX_AGE_MS) {
        logger.info('[OllamaService] Cache is stale, will fetch fresh data')
        return null
      }

      const cacheData = await fs.readFile(MODELS_CACHE_FILE, 'utf-8')
      const models = JSON.parse(cacheData) as RoachNetOllamaModel[]

      if (!Array.isArray(models)) {
        logger.warn('[OllamaService] Invalid cache format, will fetch fresh data')
        return null
      }

      return models
    } catch (error) {
      // Cache doesn't exist or is invalid
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        logger.warn(
          `[OllamaService] Error reading cache: ${error instanceof Error ? error.message : error}`
        )
      }
      return null
    }
  }

  private async writeModelsToCache(models: RoachNetOllamaModel[]): Promise<void> {
    try {
      await fs.mkdir(path.dirname(MODELS_CACHE_FILE), { recursive: true })
      await fs.writeFile(MODELS_CACHE_FILE, JSON.stringify(models, null, 2), 'utf-8')
      logger.info('[OllamaService] Successfully cached available models')
    } catch (error) {
      logger.warn(
        `[OllamaService] Failed to write models cache: ${error instanceof Error ? error.message : error}`
      )
    }
  }

  private async getPrimaryRuntimeCandidates(): Promise<Array<{ baseUrl: string; source: AIRuntimeSource }>> {
    const settingUrl = await this.readConfiguredOllamaBaseUrl()
    const configuredUrl = env.get('OLLAMA_BASE_URL')?.trim()
    const candidates: Array<{ baseUrl: string; source: AIRuntimeSource }> = []
    const seen = new Set<string>()

    const addCandidate = (baseUrl: string | null | undefined, source: AIRuntimeSource) => {
      if (!baseUrl) {
        return
      }

      const normalizedBaseUrl = this.normalizeBaseUrl(baseUrl)
      if (seen.has(normalizedBaseUrl)) {
        return
      }

      seen.add(normalizedBaseUrl)
      candidates.push({ baseUrl: normalizedBaseUrl, source })
    }

    if (process.env.ROACHNET_NATIVE_ONLY === '1') {
      addCandidate(configuredUrl, 'configured')
      addCandidate(settingUrl, 'configured')
    } else {
      addCandidate(settingUrl, 'configured')
      addCandidate(configuredUrl, 'configured')
    }
    addCandidate(DEFAULT_OLLAMA_BASE_URL, 'local')

    return candidates
  }

  private async readConfiguredOllamaBaseUrl(): Promise<string | undefined> {
    try {
      return (await KVStore.getValue('ai.ollamaBaseUrl'))?.trim()
    } catch (error) {
      logger.warn(
        `[OllamaService] Falling back to env/default Ollama host after settings lookup failed: ${
          error instanceof Error ? error.message : error
        }`
      )
      return undefined
    }
  }

  private async getDockerRuntimeCandidate(): Promise<{ baseUrl: string; source: AIRuntimeSource } | null> {
    try {
      const dockerService = new (await import('./docker_service.js')).DockerService()
      const dockerUrl = await dockerService.getServiceURL(SERVICE_NAMES.OLLAMA)
      if (!dockerUrl) {
        return null
      }

      return {
        baseUrl: this.normalizeBaseUrl(dockerUrl),
        source: 'docker',
      }
    } catch (error) {
      logger.debug(
        `[OllamaService] Skipping Docker runtime candidate lookup: ${error instanceof Error ? error.message : error}`
      )
      return null
    }
  }

  private async checkRuntimeCandidate(
    baseUrl: string,
    source: AIRuntimeSource
  ): Promise<AIRuntimeStatus> {
    try {
      await axios.get(this.buildRuntimeUrl(baseUrl, '/api/version'), {
        timeout: OllamaService.RUNTIME_PROBE_TIMEOUT_MS,
      })

      return {
        provider: 'ollama',
        available: true,
        source,
        baseUrl,
        error: null,
      }
    } catch (error) {
      return {
        provider: 'ollama',
        available: false,
        source,
        baseUrl,
        error: this.getRuntimeErrorMessage(baseUrl, error),
      }
    }
  }

  private buildRuntimeUrl(baseUrl: string, pathname: string): string {
    const normalizedBaseUrl = baseUrl.endsWith('/') ? baseUrl : `${baseUrl}/`
    return new URL(pathname.replace(/^\//, ''), normalizedBaseUrl).toString()
  }

  private normalizeBaseUrl(baseUrl: string): string {
    return baseUrl.trim().replace(/\/+$/, '')
  }

  private getRuntimeErrorMessage(baseUrl: string, error: unknown): string {
    if (axios.isAxiosError(error)) {
      if (error.response?.status) {
        return `Ollama runtime at ${baseUrl} returned HTTP ${error.response.status}.`
      }

      if (error.code) {
        return `Ollama runtime at ${baseUrl} is not reachable (${error.code}).`
      }
    }

    if (error instanceof Error && error.message) {
      return `Ollama runtime at ${baseUrl} is not reachable: ${error.message}`
    }

    return `Ollama runtime at ${baseUrl} is not reachable.`
  }

  public isCloudModel(modelName: string): boolean {
    return this.cloudInference.isCloudModel(modelName)
  }

  private async withTimeout<T>(
    label: string,
    operation: () => Promise<T>,
    timeoutMs: number
  ): Promise<T> {
    let timeoutHandle: ReturnType<typeof setTimeout> | undefined

    try {
      return await Promise.race([
        operation(),
        new Promise<T>((_, reject) => {
          timeoutHandle = setTimeout(() => {
            reject(new Error(`[OllamaService] Timed out while resolving ${label}`))
          }, timeoutMs)
        }),
      ])
    } finally {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }
    }
  }

  private sortModels(models: RoachNetOllamaModel[], sort?: 'pulls' | 'name'): RoachNetOllamaModel[] {
    if (sort === 'pulls') {
      // Sort by estimated pulls (it should be a string like "1.2K", "500", "4M" etc.)
      models.sort((a, b) => {
        const parsePulls = (pulls: string) => {
          const multiplier = pulls.endsWith('K')
            ? 1_000
            : pulls.endsWith('M')
              ? 1_000_000
              : pulls.endsWith('B')
                ? 1_000_000_000
                : 1
          return parseFloat(pulls) * multiplier
        }
        return parsePulls(b.estimated_pulls) - parsePulls(a.estimated_pulls)
      })
    } else if (sort === 'name') {
      models.sort((a, b) => a.name.localeCompare(b.name))
    }

    // Always sort model.tags by the size field in descending order
    // Size is a string like '75GB', '8.5GB', '2GB' etc. Smaller models first
    models.forEach((model) => {
      if (model.tags && Array.isArray(model.tags)) {
        model.tags.sort((a, b) => {
          const parseSize = (size: string) => {
            const multiplier = size.endsWith('KB')
              ? 1 / 1_000
              : size.endsWith('MB')
                ? 1 / 1_000_000
                : size.endsWith('GB')
                  ? 1
                  : size.endsWith('TB')
                    ? 1_000
                    : 0 // Unknown size format
            return parseFloat(size) * multiplier
          }
          return parseSize(a.size) - parseSize(b.size)
        })
      }
    })

    return models
  }

  private broadcastDownloadError(model: string, error: string) {
    void broadcastTransmit(BROADCAST_CHANNELS.OLLAMA_MODEL_DOWNLOAD, {
      model,
      percent: -1,
      error,
      timestamp: new Date().toISOString(),
    })
  }

  private broadcastDownloadProgress(model: string, percent: number) {
    void broadcastTransmit(BROADCAST_CHANNELS.OLLAMA_MODEL_DOWNLOAD, {
      model,
      percent,
      timestamp: new Date().toISOString(),
    })
    logger.info(`[OllamaService] Download progress for model "${model}": ${percent}%`)
  }

  private fuseSearchModels(models: RoachNetOllamaModel[], query: string): RoachNetOllamaModel[] {
    const options: IFuseOptions<RoachNetOllamaModel> = {
      ignoreDiacritics: true,
      keys: ['name', 'description', 'tags.name'],
      threshold: 0.3, // lower threshold for stricter matching
    }

    const fuse = new Fuse(models, options)

    return fuse.search(query).map(result => result.item)
  }
}
