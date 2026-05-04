import { inject } from '@adonisjs/core'
import type { HttpContext } from '@adonisjs/core/http'
import { SiteArchiveService } from '#services/site_archive_service'

@inject()
export default class SiteArchivesController {
  constructor(private siteArchiveService: SiteArchiveService) {}

  async index({ inertia }: HttpContext) {
    return inertia.render('site-archives/index', {})
  }

  async list({}: HttpContext) {
    return {
      archives: await this.siteArchiveService.listArchives(),
    }
  }

  async create({ request, response }: HttpContext) {
    try {
      const payload = request.only(['url', 'title'])
      return await this.siteArchiveService.createArchive(payload)
    } catch (error) {
      return response.badRequest({
        message: error instanceof Error ? error.message : 'Unable to archive that website.',
      })
    }
  }

  async destroy({ params }: HttpContext) {
    await this.siteArchiveService.deleteArchive(params.slug)
    return {
      success: true,
    }
  }

  async serve({ params, request, response }: HttpContext) {
    const requestedPath = params['*'] || request.qs().path || 'index.html'
    const normalizedPath = Array.isArray(requestedPath) ? requestedPath.join('/') : requestedPath

    if (String(normalizedPath).endsWith('.html')) {
      response.header('Cache-Control', 'no-store')
      response.type('text/html; charset=utf-8')
      return this.siteArchiveService.readArchiveHtml(params.slug, normalizedPath)
    }

    const file = await this.siteArchiveService.createArchiveStream(params.slug, normalizedPath)
    response.header('Cache-Control', 'no-store')
    response.type(file.contentType)
    return response.stream(file.stream)
  }
}
