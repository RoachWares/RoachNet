import { inject } from '@adonisjs/core'
import type { HttpContext } from '@adonisjs/core/http'
import { RoachClawService } from '#services/roachclaw_service'

@inject()
export default class RoachClawController {
  constructor(private roachClawService: RoachClawService) {}

  async getStatus({}: HttpContext) {
    return this.roachClawService.getStatus()
  }

  async apply({ request, response }: HttpContext) {
    try {
      const payload = request.only(['model', 'workspacePath', 'ollamaBaseUrl', 'openclawBaseUrl'])
      return await this.roachClawService.applyOnboarding(payload)
    } catch (error) {
      return response.badRequest({
        message: error instanceof Error ? error.message : 'Unable to apply RoachClaw onboarding.',
      })
    }
  }
}
