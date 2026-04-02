import { Logger } from '@adonisjs/core/logger'
import { HttpContext } from '@adonisjs/core/http'
import { NextFn } from '@adonisjs/core/types/http'

const traceRequests = process.env.ROACHNET_TRACE_REQUESTS === '1'

/**
 * The container bindings middleware binds classes to their request
 * specific value using the container resolver.
 *
 * - We bind "HttpContext" class to the "ctx" object
 * - And bind "Logger" class to the "ctx.logger" object
 */
export default class ContainerBindingsMiddleware {
  async handle(ctx: HttpContext, next: NextFn) {
    if (traceRequests) {
      console.error('[roachnet:req] container_bindings:start', {
        method: ctx.request.method(),
        url: ctx.request.url(true),
      })
    }

    ctx.containerResolver.bindValue(HttpContext, ctx)
    ctx.containerResolver.bindValue(Logger, ctx.logger)

    try {
      const response = await next()

      if (traceRequests) {
        console.error('[roachnet:req] container_bindings:end', {
          method: ctx.request.method(),
          url: ctx.request.url(true),
        })
      }

      return response
    } catch (error) {
      if (traceRequests) {
        console.error('[roachnet:req] container_bindings:error', {
          method: ctx.request.method(),
          url: ctx.request.url(true),
          message: error instanceof Error ? error.message : String(error),
        })
      }

      throw error
    }
  }
}
