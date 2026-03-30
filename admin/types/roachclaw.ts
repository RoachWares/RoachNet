import type { AIRuntimeStatus } from './ai.js'
import type { OpenClawSkillCliStatus } from './openclaw.js'

export interface RoachClawStatusResponse {
  label: string
  ollama: AIRuntimeStatus
  openclaw: AIRuntimeStatus
  cliStatus: OpenClawSkillCliStatus
  workspacePath: string
  defaultModel: string | null
  resolvedDefaultModel: string | null
  preferredMode: 'ollama' | 'openclaw' | 'offline'
  ready: boolean
  installedModels: string[]
  preferredModels: string[]
  configFilePath: string | null
}

export interface ApplyRoachClawRequest {
  model: string
  workspacePath?: string
  ollamaBaseUrl?: string
  openclawBaseUrl?: string
}

export interface ApplyRoachClawResponse {
  success: boolean
  message: string
  model: string
  workspacePath: string
  configFilePath: string | null
}
