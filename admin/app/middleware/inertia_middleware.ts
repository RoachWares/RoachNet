import type { HttpContext } from '@adonisjs/core/http'
import BaseInertiaMiddleware from '@adonisjs/inertia/inertia_middleware'

export default class InertiaMiddleware extends BaseInertiaMiddleware {
  async handle(ctx: HttpContext, next: () => Promise<void>) {
    await this.init(ctx)
    await next()
    this.dispose(ctx)
  }

  async share(_ctx: HttpContext) {
    const { SystemService } = await import('#services/system_service')
    const { default: KVStore } = await import('#models/kv_store')
    const customName = await KVStore.getValue('ai.assistantCustomName')

    return {
      appVersion: SystemService.getAppVersion(),
      environment: process.env.NODE_ENV || 'production',
      aiAssistantName: customName && customName.trim() ? customName : 'AI Assistant',
    }
  }
}
