import { CollectionUpdateService } from '#services/collection_update_service'
import {
  assertNotPrivateUrl,
  applyContentUpdateValidator,
  applyAllContentUpdatesValidator,
} from '#validators/common'
import type { HttpContext } from '@adonisjs/core/http'
import type { ResourceUpdateInfo } from '../../types/collections.js'

export default class CollectionUpdatesController {
  async checkForUpdates({}: HttpContext) {
    const service = new CollectionUpdateService()
    return await service.checkForUpdates()
  }

  async applyUpdate({ request }: HttpContext) {
    const update = (await request.validateUsing(applyContentUpdateValidator)) as ResourceUpdateInfo
    assertNotPrivateUrl(update.download_url)
    const service = new CollectionUpdateService()
    return await service.applyUpdate(update)
  }

  async applyAllUpdates({ request }: HttpContext) {
    const { updates } = (await request.validateUsing(applyAllContentUpdatesValidator)) as {
      updates: ResourceUpdateInfo[]
    }
    for (const update of updates) {
      assertNotPrivateUrl(update.download_url)
    }
    const service = new CollectionUpdateService()
    return await service.applyAllUpdates(updates)
  }
}
