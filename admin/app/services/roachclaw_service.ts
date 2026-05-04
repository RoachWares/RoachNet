import { inject } from '@adonisjs/core'
import KVStore from '#models/kv_store'
import env from '#start/env'
import { AIRuntimeService } from '#services/ai_runtime_service'
import { OllamaService } from '#services/ollama_service'
import { OpenClawService } from '#services/openclaw_service'
import { spawn } from 'node:child_process'
import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'
import logger from '@adonisjs/core/services/logger'
import type {
  ApplyRoachClawRequest,
  ApplyRoachClawResponse,
  RoachClawPortableProfile,
  RoachClawStatusResponse,
} from '../../types/roachclaw.js'
import { getErrorMessage } from '../utils/errors.js'
import { findCommandPath } from '../utils/process.js'
import { PREFERRED_ROACHCLAW_MODELS } from '../../constants/ollama.js'

const ROACHCLAW_OPENCLAW_STATE_DIRNAME = '.openclaw-runtime'
const ROACHCLAW_PROFILE_VERSION = 2

@inject()
export class RoachClawService {
  constructor(
    private aiRuntimeService: AIRuntimeService,
    private ollamaService: OllamaService,
    private openClawService: OpenClawService
  ) {}

  private async withTimeout<T>(work: Promise<T>, timeoutMs: number, fallback: T): Promise<T> {
    let timeoutHandle: NodeJS.Timeout | undefined

    try {
      return await Promise.race([
        work,
        new Promise<T>((resolve) => {
          timeoutHandle = setTimeout(() => resolve(fallback), timeoutMs)
        }),
      ])
    } finally {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle)
      }
    }
  }

  public async getStatus(): Promise<RoachClawStatusResponse> {
    const [ollama, openclaw, cliStatus, defaultModel, storedOllamaBaseUrl, storedOpenClawBaseUrl] =
      await Promise.all([
        this.aiRuntimeService.getProvider('ollama'),
        this.aiRuntimeService.getProvider('openclaw'),
        this.openClawService.getSkillCliStatus(),
        KVStore.getValue('ai.roachclawDefaultModel'),
        KVStore.getValue('ai.ollamaBaseUrl'),
        KVStore.getValue('ai.openclawBaseUrl'),
      ])

    let installedModels: string[] = []
    if (ollama.available) {
      try {
        installedModels = (
          await this.withTimeout<Array<{ name: string }>>(
            this.ollamaService.getModels() as Promise<Array<{ name: string }>>,
            2_500,
            []
          )
        )
          .map((model: { name: string }) => model.name)
          .filter((modelName: string) => !modelName.endsWith(':cloud'))
      } catch {
        installedModels = []
      }
    }

    const resolvedDefaultModel =
      this.resolveDefaultModel(defaultModel, installedModels) || null
    const preferredMode = openclaw.available
      ? 'openclaw'
      : ollama.available
        ? 'ollama'
        : 'offline'
    const ready = ollama.available && Boolean(resolvedDefaultModel)

    const configFilePath = cliStatus.openclawAvailable
      ? (await this.tryGetOpenClawConfigPath(cliStatus.workspacePath))
      : null
    const portableProfile = this.buildPortableProfile({
      workspacePath: cliStatus.workspacePath,
      model: resolvedDefaultModel || defaultModel,
      preferredMode,
      installedModels,
      preferredModels: [...PREFERRED_ROACHCLAW_MODELS],
      ollamaBaseUrl: ollama.baseUrl || (storedOllamaBaseUrl as string | null) || env.get('OLLAMA_BASE_URL') || null,
      openclawBaseUrl:
        openclaw.baseUrl || (storedOpenClawBaseUrl as string | null) || env.get('OPENCLAW_BASE_URL') || null,
      configFilePath,
      updatedAt: new Date().toISOString(),
    })

    return {
      label: 'RoachClaw',
      ollama,
      openclaw,
      cliStatus,
      workspacePath: cliStatus.workspacePath,
      defaultModel,
      resolvedDefaultModel,
      preferredMode,
      ready,
      installedModels,
      preferredModels: [...PREFERRED_ROACHCLAW_MODELS],
      configFilePath,
      portableProfile,
    }
  }

  public async getPortableProfile(): Promise<RoachClawPortableProfile> {
    const status = await this.getStatus()
    return status.portableProfile!
  }

  public async applyOnboarding(payload: ApplyRoachClawRequest): Promise<ApplyRoachClawResponse> {
    const normalizedModel = payload.model.trim()
    if (!normalizedModel) {
      throw new Error('A local Ollama model is required for RoachClaw.')
    }

    const workspacePath = path.resolve(
      payload.workspacePath?.trim() ||
        ((await KVStore.getValue('ai.openclawWorkspacePath')) as string | null) ||
        env.get('OPENCLAW_WORKSPACE_PATH') ||
        path.join(process.cwd(), 'storage', 'openclaw')
    )
    const preferNativeManagedLane = process.env.ROACHNET_NATIVE_ONLY === '1'
    const ollamaBaseUrl =
      payload.ollamaBaseUrl?.trim() ||
      (preferNativeManagedLane
        ? env.get('OLLAMA_BASE_URL') || ((await KVStore.getValue('ai.ollamaBaseUrl')) as string | null)
        : ((await KVStore.getValue('ai.ollamaBaseUrl')) as string | null) || env.get('OLLAMA_BASE_URL')) ||
      'http://127.0.0.1:11434'
    const openclawBaseUrl =
      payload.openclawBaseUrl?.trim() ||
      (preferNativeManagedLane
        ? env.get('OPENCLAW_BASE_URL') || ((await KVStore.getValue('ai.openclawBaseUrl')) as string | null)
        : ((await KVStore.getValue('ai.openclawBaseUrl')) as string | null) || env.get('OPENCLAW_BASE_URL')) ||
      'http://127.0.0.1:3001'

    await mkdir(workspacePath, { recursive: true })

    const currentModels = await this.getInstalledModelNames()
    if (!currentModels.includes(normalizedModel)) {
      await this.ollamaService.dispatchModelDownload(normalizedModel)
    }

    await Promise.all([
      KVStore.setValue('ai.ollamaBaseUrl', ollamaBaseUrl),
      KVStore.setValue('ai.openclawBaseUrl', openclawBaseUrl),
      KVStore.setValue('ai.openclawWorkspacePath', workspacePath),
      KVStore.setValue('ai.roachclawDefaultModel', normalizedModel),
    ])

    const configFilePath = await this.tryGetOpenClawConfigPath(workspacePath)

    await this.writeRoachClawProfile({
      workspacePath,
      model: normalizedModel,
      preferredMode: 'openclaw',
      installedModels: currentModels.includes(normalizedModel)
        ? currentModels
        : [...currentModels, normalizedModel],
      preferredModels: [...PREFERRED_ROACHCLAW_MODELS],
      ollamaBaseUrl,
      openclawBaseUrl,
      configFilePath,
    })

    // Do not block the first-boot UX on OpenClaw CLI reconciliation. The
    // contained Ollama download queue is the critical path; the CLI settings can
    // converge in the background once the local lane is staged.
    void this.reconcileOpenClawCliConfig({
      workspacePath,
      model: normalizedModel,
      ollamaBaseUrl,
      openclawBaseUrl,
    })

    return {
      success: true,
      message:
        `RoachClaw saved ${normalizedModel} as the contained default model and ` +
        `queued any missing local download. OpenClaw is reconciling in the background.`,
      model: normalizedModel,
      workspacePath,
      configFilePath,
    }
  }

  private async getInstalledModelNames(): Promise<string[]> {
    try {
      return (await (this.ollamaService.getModels() as Promise<Array<{ name: string }>>))
        .map((model: { name: string }) => model.name)
        .filter((modelName: string) => !modelName.endsWith(':cloud'))
    } catch {
      return []
    }
  }

  private resolveDefaultModel(defaultModel: string | null, installedModels: string[]): string | null {
    if (defaultModel && installedModels.includes(defaultModel)) {
      return defaultModel
    }

    for (const candidate of PREFERRED_ROACHCLAW_MODELS) {
      if (installedModels.includes(candidate)) {
        return candidate
      }
    }

    const preferredMatchers = [/^qwen2\.5-coder:/i, /^qwen3\.5:/i, /^qwen2\.5:/i, /^llama/i, /^gemma/i]
    for (const matcher of preferredMatchers) {
      const match = installedModels.find((modelName) => matcher.test(modelName))
      if (match) {
        return match
      }
    }

    return installedModels[0] ?? null
  }

  private getOpenClawBinary(): string {
    return process.platform === 'win32' ? 'openclaw.cmd' : 'openclaw'
  }

  private getNpxBinary(): string {
    return process.platform === 'win32' ? 'npx.cmd' : 'npx'
  }

  private async commandExists(binary: string): Promise<boolean> {
    return Boolean(await findCommandPath(binary))
  }

  private async runOpenClawCommand(args: string[], cwd: string): Promise<{ stdout: string; stderr: string }> {
    await mkdir(cwd, { recursive: true })
    const openclawEnv = await this.getOpenClawProcessEnv(cwd)

    if (await this.commandExists(this.getOpenClawBinary())) {
      return this.runCommand(this.getOpenClawBinary(), args, cwd, openclawEnv)
    }

    return this.runCommand(this.getNpxBinary(), ['-y', 'openclaw', ...args], cwd, openclawEnv)
  }

  private async runCommand(
    binary: string,
    args: string[],
    cwd: string,
    envOverrides: NodeJS.ProcessEnv = {}
  ): Promise<{ stdout: string; stderr: string }> {
    return new Promise((resolve, reject) => {
      const child = spawn(binary, args, {
        cwd,
        env: {
          ...process.env,
          ...envOverrides,
        },
        stdio: ['ignore', 'pipe', 'pipe'],
      })

      let stdout = ''
      let stderr = ''

      child.stdout.on('data', (chunk) => {
        stdout += chunk.toString()
      })

      child.stderr.on('data', (chunk) => {
        stderr += chunk.toString()
      })

      child.on('error', reject)
      child.on('close', (code) => {
        if (code === 0) {
          resolve({ stdout, stderr })
          return
        }

        reject(new Error(`${binary} ${args.join(' ')} exited with code ${code}\n${stderr.trim() || stdout.trim()}`))
      })
    })
  }

  private async applyOpenClawCliConfig(
    workspacePath: string,
    model: string,
    ollamaBaseUrl: string
  ): Promise<{ failures: string[] }> {
    const normalizedBaseUrl = ollamaBaseUrl.replace(/\/+$/, '')
    const failures: string[] = []
    let totalWrites = 3

    try {
      await this.runOpenClawSetupCommand(workspacePath)
    } catch (error) {
      logger.warn(
        `[RoachClawService] OpenClaw setup did not complete cleanly: ${getErrorMessage(error)}`
      )
    }

    await this.waitForOpenClawConfigReady(workspacePath)

    const writeCommand = async (args: string[]) => {
      try {
        await this.runOpenClawCommand(args, workspacePath)
      } catch (error) {
        const errorMessage = getErrorMessage(error)
        failures.push(`${args.join(' ')}: ${errorMessage}`)
        logger.warn(
          `[RoachClawService] OpenClaw CLI command failed (${args.join(' ')}): ${errorMessage}`
        )
      }
    }

    await writeCommand(['config', 'set', 'agents.defaults.workspace', workspacePath])
    await writeCommand(['config', 'set', 'models.providers.ollama.apiKey', 'ollama-local'])

    if (normalizedBaseUrl !== 'http://127.0.0.1:11434' && normalizedBaseUrl !== 'http://localhost:11434') {
      totalWrites += 2
      await writeCommand([
        'config',
        'set',
        'models.providers.ollama.baseUrl',
        normalizedBaseUrl,
      ])
      await writeCommand(['config', 'set', 'models.providers.ollama.api', 'ollama'])
    }

    await writeCommand(['models', 'set', `ollama/${model}`])

    if (failures.length >= totalWrites) {
      throw new Error('OpenClaw CLI accepted the onboarding request, but the config writes did not settle yet.')
    }

    return { failures }
  }

  private async waitForOpenClawConfigReady(workspacePath: string): Promise<void> {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      try {
        const configPath = await this.tryGetOpenClawConfigPath(workspacePath)
        if (configPath) {
          return
        }
      } catch {
        // Keep polling for the config path to settle after setup.
      }

      await new Promise((resolve) => setTimeout(resolve, 250))
    }
  }

  private async runOpenClawSetupCommand(workspacePath: string): Promise<void> {
    let lastError: unknown = null

    for (let attempt = 1; attempt <= 2; attempt += 1) {
      try {
        await this.runOpenClawCommand(['setup', '--workspace', workspacePath], workspacePath)
        return
      } catch (error) {
        lastError = error
        if (attempt === 2) {
          break
        }

        await new Promise((resolve) => setTimeout(resolve, 1000))
      }
    }

    throw lastError instanceof Error ? lastError : new Error('OpenClaw setup failed.')
  }

  private async tryGetOpenClawConfigPath(workspacePath: string): Promise<string | null> {
    try {
      const result = await this.runOpenClawCommand(['config', 'file'], workspacePath)
      return result.stdout.trim() || null
    } catch {
      return null
    }
  }

  private async getOpenClawProcessEnv(workspacePath: string): Promise<NodeJS.ProcessEnv> {
    const normalizedWorkspacePath = path.resolve(workspacePath)
    const runtimeStateDir = path.join(normalizedWorkspacePath, ROACHCLAW_OPENCLAW_STATE_DIRNAME)
    const configPath = path.join(runtimeStateDir, 'openclaw.json')

    await mkdir(runtimeStateDir, { recursive: true })

    return {
      OPENCLAW_WORKSPACE_PATH: normalizedWorkspacePath,
      OPENCLAW_STATE_DIR: runtimeStateDir,
      OPENCLAW_CONFIG_PATH: configPath,
    }
  }

  private async writeRoachClawProfile(input: {
    workspacePath: string
    model: string | null
    preferredMode: 'ollama' | 'openclaw' | 'offline'
    installedModels: string[]
    preferredModels: string[]
    ollamaBaseUrl: string
    openclawBaseUrl: string
    configFilePath: string | null
  }) {
    const profile = this.buildPortableProfile({
      workspacePath: input.workspacePath,
      model: input.model,
      preferredMode: input.preferredMode,
      installedModels: input.installedModels,
      preferredModels: input.preferredModels,
      ollamaBaseUrl: input.ollamaBaseUrl,
      openclawBaseUrl: input.openclawBaseUrl,
      configFilePath: input.configFilePath,
      updatedAt: new Date().toISOString(),
    })

    await writeFile(
      profile.profilePath,
      JSON.stringify(profile, null, 2) + '\n',
      'utf8'
    )
  }

  private async reconcileOpenClawCliConfig(input: {
    workspacePath: string
    model: string
    ollamaBaseUrl: string
    openclawBaseUrl: string
  }) {
    try {
      const cliConfigResult = await this.applyOpenClawCliConfig(
        input.workspacePath,
        input.model,
        input.ollamaBaseUrl
      )
      const configFilePath = await this.tryGetOpenClawConfigPath(input.workspacePath)

      await this.writeRoachClawProfile({
        workspacePath: input.workspacePath,
        model: input.model,
        preferredMode: 'openclaw',
        installedModels: await this.getInstalledModelNames(),
        preferredModels: [...PREFERRED_ROACHCLAW_MODELS],
        ollamaBaseUrl: input.ollamaBaseUrl,
        openclawBaseUrl: input.openclawBaseUrl,
        configFilePath,
      })

      if (cliConfigResult.failures.length > 0) {
        logger.warn(
          `[RoachClawService] OpenClaw CLI finished with ${cliConfigResult.failures.length} non-fatal issue(s).`
        )
      }
    } catch (error) {
      logger.warn(
        `[RoachClawService] Background OpenClaw reconciliation did not finish cleanly: ${getErrorMessage(error)}`
      )
    }
  }

  private buildPortableProfile(input: {
    workspacePath: string
    model: string | null
    preferredMode: 'ollama' | 'openclaw' | 'offline'
    installedModels: string[]
    preferredModels: string[]
    ollamaBaseUrl: string | null
    openclawBaseUrl: string | null
    configFilePath: string | null
    updatedAt: string
  }): RoachClawPortableProfile {
    const workspacePath = path.resolve(input.workspacePath)
    const stateDir = path.join(workspacePath, ROACHCLAW_OPENCLAW_STATE_DIRNAME)
    const portableRoot = this.resolvePortableRoot(workspacePath)
    const contained =
      process.env.ROACHNET_NATIVE_ONLY === '1' ||
      Boolean(process.env.ROACHNET_STORAGE_PATH?.trim()) ||
      (path.basename(workspacePath) === 'openclaw' && path.basename(path.dirname(workspacePath)) === 'storage')
    const runtimeHints: RoachClawPortableProfile['runtimeHints'] = {
      contained,
      launchMode: contained ? 'native-contained' : 'configured-runtime',
      notes: [
        contained
          ? 'RoachClaw is pinned to the contained RoachNet runtime lane.'
          : 'RoachClaw is using configured runtime endpoints outside the contained lane.',
        input.model
          ? `RoachClaw will prefer ${input.model} first.`
          : 'RoachClaw will fall back to the first available preferred local model.',
        input.openclawBaseUrl
          ? `OpenClaw endpoint: ${input.openclawBaseUrl}`
          : 'OpenClaw will stay on runtime discovery until an endpoint is pinned.',
      ],
    }

    return {
      profileVersion: ROACHCLAW_PROFILE_VERSION,
      label: 'RoachClaw',
      profilePath: path.join(workspacePath, 'roachclaw.profile.json'),
      portableRoot,
      workspacePath,
      stateDir,
      configFilePath: input.configFilePath,
      preferredMode: input.preferredMode,
      defaultModel: input.model,
      preferredModels: [...input.preferredModels],
      installedModels: [...input.installedModels],
      providerEndpoints: {
        ollamaBaseUrl: input.ollamaBaseUrl,
        openclawBaseUrl: input.openclawBaseUrl,
      },
      runtimeHints,
      updatedAt: input.updatedAt,
    }
  }

  private resolvePortableRoot(workspacePath: string): string {
    const explicitPortableRoot = process.env.ROACHNET_STORAGE_PATH?.trim()

    if (explicitPortableRoot) {
      return path.resolve(explicitPortableRoot)
    }

    if (path.basename(workspacePath) === 'openclaw') {
      return path.dirname(workspacePath)
    }

    return path.dirname(workspacePath)
  }
}
