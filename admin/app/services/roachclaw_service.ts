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
  RoachClawStatusResponse,
} from '../../types/roachclaw.js'
import { getErrorMessage } from '../utils/errors.js'
import { findCommandPath } from '../utils/process.js'
import { PREFERRED_ROACHCLAW_MODELS } from '../../constants/ollama.js'

@inject()
export class RoachClawService {
  constructor(
    private aiRuntimeService: AIRuntimeService,
    private ollamaService: OllamaService,
    private openClawService: OpenClawService
  ) {}

  public async getStatus(): Promise<RoachClawStatusResponse> {
    const [ollama, openclaw, cliStatus, defaultModel] = await Promise.all([
      this.aiRuntimeService.getProvider('ollama'),
      this.aiRuntimeService.getProvider('openclaw'),
      this.openClawService.getSkillCliStatus(),
      KVStore.getValue('ai.roachclawDefaultModel'),
    ])

    let installedModels: string[] = []
    if (ollama.available) {
      try {
        installedModels = (await this.ollamaService.getModels())
          .map((model) => model.name)
          .filter((modelName) => !modelName.endsWith(':cloud'))
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
    }
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
    const ollamaBaseUrl =
      payload.ollamaBaseUrl?.trim() ||
      ((await KVStore.getValue('ai.ollamaBaseUrl')) as string | null) ||
      env.get('OLLAMA_BASE_URL') ||
      'http://127.0.0.1:11434'
    const openclawBaseUrl =
      payload.openclawBaseUrl?.trim() ||
      ((await KVStore.getValue('ai.openclawBaseUrl')) as string | null) ||
      env.get('OPENCLAW_BASE_URL') ||
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

    let configFilePath: string | null = null
    let message = `RoachClaw saved ${normalizedModel} as the default local model.`

    try {
      const cliConfigResult = await this.applyOpenClawCliConfig(
        workspacePath,
        normalizedModel,
        ollamaBaseUrl
      )
      configFilePath = await this.tryGetOpenClawConfigPath(workspacePath)
      if (cliConfigResult.failures.length === 0) {
        message =
          `RoachClaw configured OpenClaw to default to ollama/${normalizedModel} ` +
          `and set the workspace to ${workspacePath}.`
      } else {
        message =
          `RoachClaw saved the local defaults and applied OpenClaw CLI settings with ` +
          `${cliConfigResult.failures.length} non-fatal issue(s). Check the server logs if a CLI value did not stick yet.`
      }
    } catch (error) {
      logger.warn(
        `[RoachClawService] OpenClaw CLI configuration did not finish cleanly: ${getErrorMessage(error)}`
      )
      message += ' OpenClaw CLI config did not finish cleanly, so only the RoachNet-side defaults were guaranteed.'
    }

    await this.writeRoachClawProfile({
      workspacePath,
      model: normalizedModel,
      ollamaBaseUrl,
      openclawBaseUrl,
      configFilePath,
    })

    return {
      success: true,
      message,
      model: normalizedModel,
      workspacePath,
      configFilePath,
    }
  }

  private async getInstalledModelNames(): Promise<string[]> {
    try {
      return (await this.ollamaService.getModels())
        .map((model) => model.name)
        .filter((modelName) => !modelName.endsWith(':cloud'))
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

    if (await this.commandExists(this.getOpenClawBinary())) {
      return this.runCommand(this.getOpenClawBinary(), args, cwd)
    }

    return this.runCommand(this.getNpxBinary(), ['-y', 'openclaw', ...args], cwd)
  }

  private async runCommand(binary: string, args: string[], cwd: string): Promise<{ stdout: string; stderr: string }> {
    return new Promise((resolve, reject) => {
      const child = spawn(binary, args, {
        cwd,
        env: process.env,
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

  private async writeRoachClawProfile(input: {
    workspacePath: string
    model: string
    ollamaBaseUrl: string
    openclawBaseUrl: string
    configFilePath: string | null
  }) {
    const profilePath = path.join(input.workspacePath, 'roachclaw.profile.json')
    await writeFile(
      profilePath,
      JSON.stringify(
        {
          name: 'RoachClaw',
          model: input.model,
          ollamaBaseUrl: input.ollamaBaseUrl,
          openclawBaseUrl: input.openclawBaseUrl,
          configFilePath: input.configFilePath,
          updatedAt: new Date().toISOString(),
        },
        null,
        2
      ) + '\n',
      'utf8'
    )
  }
}
