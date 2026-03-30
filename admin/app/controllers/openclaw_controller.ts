import { OpenClawService } from '#services/openclaw_service'
import { inject } from '@adonisjs/core'
import type { HttpContext } from '@adonisjs/core/http'

@inject()
export default class OpenClawController {
  constructor(private openClawService: OpenClawService) {}

  async getSkillCliStatus({ response }: HttpContext) {
    response.send(await this.openClawService.getSkillCliStatus())
  }

  async searchSkills({ request, response }: HttpContext) {
    const query = String(request.qs().query || '').trim()
    const limit = Math.max(1, Math.min(Number(request.qs().limit || 8), 20))

    response.send(await this.openClawService.searchSkills(query, limit))
  }

  async listInstalledSkills({ response }: HttpContext) {
    response.send(await this.openClawService.getInstalledSkills())
  }

  async installSkill({ request, response }: HttpContext) {
    const slug = String(request.input('slug') || '').trim()
    const version = request.input('version') ? String(request.input('version')).trim() : undefined

    if (!slug) {
      response.status(422).send({ error: 'A ClawHub skill slug is required.' })
      return
    }

    try {
      response.send(await this.openClawService.installSkill(slug, version))
    } catch (error) {
      response.status(400).send({
        error: error instanceof Error ? error.message : 'Failed to install ClawHub skill.',
      })
    }
  }
}
