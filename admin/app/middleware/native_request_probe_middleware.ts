import { HttpContext } from '@adonisjs/core/http'
import { NextFn } from '@adonisjs/core/types/http'

const traceRequests = process.env.ROACHNET_TRACE_REQUESTS === '1'

export default class NativeRequestProbeMiddleware {
  async handle(ctx: HttpContext, next: NextFn) {
    if (traceRequests) {
      console.error('[roachnet:req] router_probe:start', {
        method: ctx.request.method(),
        url: ctx.request.url(true),
      })
    }

    try {
      const response = await next()

      if (traceRequests) {
        console.error('[roachnet:req] router_probe:end', {
          method: ctx.request.method(),
          url: ctx.request.url(true),
          status: ctx.response.getStatus(),
        })
      }

      return response
    } catch (error) {
      if (traceRequests) {
        console.error('[roachnet:req] router_probe:error', {
          method: ctx.request.method(),
          url: ctx.request.url(true),
          message: error instanceof Error ? error.message : String(error),
        })
      }

      throw error
    }
  }
}
