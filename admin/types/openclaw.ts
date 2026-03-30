export interface OpenClawSkillSearchResult {
  slug: string
  title: string
  score: number | null
}

export interface InstalledOpenClawSkill {
  slug: string
  name: string
  description: string | null
  homepage: string | null
  path: string
}

export interface OpenClawSkillCliStatus {
  openclawAvailable: boolean
  clawhubAvailable: boolean
  workspacePath: string
  runner: 'cli' | 'npx' | 'none'
}

export interface OpenClawSkillSearchResponse {
  query: string
  workspacePath: string
  skills: OpenClawSkillSearchResult[]
  cliStatus: OpenClawSkillCliStatus
}

export interface OpenClawInstalledSkillsResponse {
  workspacePath: string
  skills: InstalledOpenClawSkill[]
  cliStatus: OpenClawSkillCliStatus
}

export interface OpenClawInstallSkillResponse {
  success: boolean
  message: string
  workspacePath: string
  skill: InstalledOpenClawSkill | null
  cliStatus: OpenClawSkillCliStatus
}
