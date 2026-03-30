import { inject } from '@adonisjs/core'
import logger from '@adonisjs/core/services/logger'
import axios from 'axios'
import env from '#start/env'
import KVStore from '#models/kv_store'
import { spawn } from 'node:child_process'
import { mkdir, readdir, readFile } from 'node:fs/promises'
import path from 'node:path'
import type { AIRuntimeSource, AIRuntimeStatus } from '../../types/ai.js'
import type {
  InstalledOpenClawSkill,
  OpenClawInstallSkillResponse,
  OpenClawInstalledSkillsResponse,
  OpenClawSkillCliStatus,
  OpenClawSkillSearchResponse,
  OpenClawSkillSearchResult,
} from '../../types/openclaw.js'

const OPENCLAW_HEALTH_PATHS = ['/health', '/api/health', '/']
const DEFAULT_OPENCLAW_WORKSPACE_PATH = path.join(process.cwd(), 'storage', 'openclaw')

@inject()
export class OpenClawService {
  public async getRuntimeStatus(): Promise<AIRuntimeStatus> {
    const candidates = await this.getRuntimeCandidates()
    let lastError: string | null = null

    for (const candidate of candidates) {
      const runtimeStatus = await this.checkRuntimeCandidate(candidate.baseUrl, candidate.source)
      if (runtimeStatus.available) {
        return runtimeStatus
      }

      lastError = runtimeStatus.error || lastError
    }

    return {
      provider: 'openclaw',
      available: false,
      source: 'none',
      baseUrl: null,
      error: lastError || 'OpenClaw runtime is not configured.',
    }
  }

  public async getSkillCliStatus(): Promise<OpenClawSkillCliStatus> {
    const workspacePath = await this.getWorkspacePath()
    const openclawBinaryAvailable = await this.commandExists('openclaw', ['--help'])
    const clawhubInstalled = await this.commandExists('clawhub', ['--help'])
    const npxClawhubAvailable = clawhubInstalled || (await this.commandExists(this.getNpxBinary(), ['-y', 'clawhub', '--help']))

    return {
      openclawAvailable: openclawBinaryAvailable,
      clawhubAvailable: npxClawhubAvailable,
      workspacePath,
      runner: openclawBinaryAvailable || clawhubInstalled ? 'cli' : npxClawhubAvailable ? 'npx' : 'none',
    }
  }

  public async searchSkills(query: string, limit = 8): Promise<OpenClawSkillSearchResponse> {
    const normalizedQuery = query.trim()
    const cliStatus = await this.getSkillCliStatus()

    if (!normalizedQuery) {
      return {
        query: '',
        workspacePath: cliStatus.workspacePath,
        skills: [],
        cliStatus,
      }
    }

    if (!cliStatus.clawhubAvailable) {
      return {
        query: normalizedQuery,
        workspacePath: cliStatus.workspacePath,
        skills: [],
        cliStatus,
      }
    }

    const result = await this.runClawhubCommand(
      ['search', normalizedQuery, '--limit', String(Math.max(1, Math.min(limit, 20)))],
      cliStatus.workspacePath
    )

    return {
      query: normalizedQuery,
      workspacePath: cliStatus.workspacePath,
      skills: this.parseSearchOutput(result.stdout),
      cliStatus,
    }
  }

  public async getInstalledSkills(): Promise<OpenClawInstalledSkillsResponse> {
    const cliStatus = await this.getSkillCliStatus()
    const skillsDir = path.join(cliStatus.workspacePath, 'skills')
    await mkdir(skillsDir, { recursive: true })

    const entries = await readdir(skillsDir, { withFileTypes: true })
    const skills = await Promise.all(
      entries
        .filter((entry) => entry.isDirectory())
        .map(async (entry) => this.readInstalledSkill(path.join(skillsDir, entry.name), entry.name))
    )

    return {
      workspacePath: cliStatus.workspacePath,
      skills: skills.filter(Boolean) as InstalledOpenClawSkill[],
      cliStatus,
    }
  }

  public async installSkill(slug: string, version?: string): Promise<OpenClawInstallSkillResponse> {
    const normalizedSlug = slug.trim()
    if (!normalizedSlug) {
      throw new Error('A ClawHub skill slug is required.')
    }

    const cliStatus = await this.getSkillCliStatus()
    if (!cliStatus.clawhubAvailable) {
      throw new Error('ClawHub CLI is not available. Install Node.js/npm or the clawhub CLI first.')
    }

    await mkdir(cliStatus.workspacePath, { recursive: true })

    const args = ['install', normalizedSlug]
    if (version?.trim()) {
      args.push('--version', version.trim())
    }

    await this.runClawhubCommand(args, cliStatus.workspacePath)

    const installedSkill = await this.readInstalledSkill(
      path.join(cliStatus.workspacePath, 'skills', normalizedSlug),
      normalizedSlug
    )

    return {
      success: true,
      message: `Installed OpenClaw skill "${normalizedSlug}" into ${cliStatus.workspacePath}.`,
      workspacePath: cliStatus.workspacePath,
      skill: installedSkill,
      cliStatus,
    }
  }

  private async getRuntimeCandidates(): Promise<Array<{ baseUrl: string; source: AIRuntimeSource }>> {
    const settingUrl = (await KVStore.getValue('ai.openclawBaseUrl'))?.trim()
    const configuredUrl = env.get('OPENCLAW_BASE_URL')?.trim()
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

    addCandidate(settingUrl, 'configured')
    addCandidate(configuredUrl, 'configured')
    addCandidate('http://127.0.0.1:3001', 'local')
    addCandidate('http://localhost:3001', 'local')

    return candidates
  }

  private async checkRuntimeCandidate(
    baseUrl: string,
    source: AIRuntimeSource
  ): Promise<AIRuntimeStatus> {
    let lastError: string | null = null

    for (const pathname of OPENCLAW_HEALTH_PATHS) {
      try {
        const response = await axios.get(this.buildRuntimeUrl(baseUrl, pathname), {
          timeout: 2000,
          validateStatus: () => true,
        })

        if (response.status >= 200 && response.status < 500 && response.status !== 404) {
          return {
            provider: 'openclaw',
            available: true,
            source,
            baseUrl,
            error: null,
          }
        }

        lastError = `OpenClaw runtime at ${baseUrl} returned HTTP ${response.status}.`
      } catch (error) {
        lastError = this.getRuntimeErrorMessage(baseUrl, error)
      }
    }

    logger.debug(`[OpenClawService] Runtime probe failed for ${baseUrl}: ${lastError}`)

    return {
      provider: 'openclaw',
      available: false,
      source,
      baseUrl,
      error: lastError,
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
        return `OpenClaw runtime at ${baseUrl} returned HTTP ${error.response.status}.`
      }

      if (error.code) {
        return `OpenClaw runtime at ${baseUrl} is not reachable (${error.code}).`
      }
    }

    if (error instanceof Error && error.message) {
      return `OpenClaw runtime at ${baseUrl} is not reachable: ${error.message}`
    }

    return `OpenClaw runtime at ${baseUrl} is not reachable.`
  }

  private async getWorkspacePath(): Promise<string> {
    const settingPath = (await KVStore.getValue('ai.openclawWorkspacePath'))?.trim()
    const configuredPath = env.get('OPENCLAW_WORKSPACE_PATH')?.trim()
    return path.resolve(settingPath || configuredPath || DEFAULT_OPENCLAW_WORKSPACE_PATH)
  }

  private getNpxBinary(): string {
    return process.platform === 'win32' ? 'npx.cmd' : 'npx'
  }

  private async commandExists(binary: string, args: string[]): Promise<boolean> {
    try {
      await this.runCommand(binary, args, process.cwd())
      return true
    } catch {
      return false
    }
  }

  private async runClawhubCommand(args: string[], cwd: string): Promise<{ stdout: string; stderr: string }> {
    await mkdir(cwd, { recursive: true })

    if (await this.commandExists('clawhub', ['--help'])) {
      try {
        return await this.runCommand('clawhub', args, cwd)
      } catch (error) {
        if (!this.isCommandNotFoundError(error)) {
          throw error
        }
      }
    }

    return this.runCommand(this.getNpxBinary(), ['-y', 'clawhub', ...args], cwd)
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

        reject(
          new Error(
            `${binary} ${args.join(' ')} exited with code ${code}\n${stderr.trim() || stdout.trim()}`
          )
        )
      })
    })
  }

  private isCommandNotFoundError(error: unknown): boolean {
    return error instanceof Error && error.message.includes('ENOENT')
  }

  private parseSearchOutput(output: string): OpenClawSkillSearchResult[] {
    return output
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0 && !line.startsWith('- Searching'))
      .map<OpenClawSkillSearchResult | null>((line) => {
        const match = line.match(/^(\S+)\s{2,}(.+?)\s+\(([\d.]+)\)$/)
        if (!match) {
          return null
        }

        return {
          slug: match[1],
          title: match[2],
          score: Number(match[3]),
        }
      })
      .filter((entry): entry is OpenClawSkillSearchResult => Boolean(entry))
  }

  private async readInstalledSkill(skillPath: string, fallbackSlug: string): Promise<InstalledOpenClawSkill | null> {
    const skillFilePath = path.join(skillPath, 'SKILL.md')

    try {
      const content = await readFile(skillFilePath, 'utf8')
      const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---/)
      const frontmatter = frontmatterMatch?.[1] || ''
      const name = frontmatter.match(/^name:\s*(.+)$/m)?.[1]?.trim() || fallbackSlug
      const description = frontmatter.match(/^description:\s*(.+)$/m)?.[1]?.trim() || null
      const homepage = frontmatter.match(/^homepage:\s*(.+)$/m)?.[1]?.trim() || null

      return {
        slug: fallbackSlug,
        name,
        description,
        homepage,
        path: skillPath,
      }
    } catch {
      return {
        slug: fallbackSlug,
        name: fallbackSlug,
        description: null,
        homepage: null,
        path: skillPath,
      }
    }
  }
}
